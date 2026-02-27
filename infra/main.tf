################################################################################
# Terraform & Provider Configuration
################################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "aws" {
  region = var.region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

################################################################################
# Data Sources
################################################################################

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

################################################################################
# VPC
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.prefix}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]

  enable_nat_gateway   = false
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = 1
    "kubernetes.io/cluster/${var.prefix}-cluster" = "owned"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = 1
    "kubernetes.io/cluster/${var.prefix}-cluster" = "owned"
  }

  tags = {
    Project = var.prefix
  }
}

################################################################################
# NAT Instance (fck-nat, replaces NAT Gateway to save ~$30/mo)
################################################################################

data "aws_ami" "fck_nat" {
  most_recent = true
  owners      = ["568608671756"]

  filter {
    name   = "name"
    values = ["fck-nat-al2023-*-arm64-ebs"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_security_group" "nat" {
  name_prefix = "${var.prefix}-nat-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.prefix}-nat"
    Project = var.prefix
  }
}

resource "aws_instance" "nat" {
  ami                         = data.aws_ami.fck_nat.id
  instance_type               = "t4g.nano"
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.nat.id]
  source_dest_check           = false
  associate_public_ip_address = true

  tags = {
    Name    = "${var.prefix}-nat"
    Project = var.prefix
  }
}

resource "aws_route" "private_nat" {
  count                  = length(module.vpc.private_route_table_ids)
  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
}

################################################################################
# EKS Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${var.prefix}-cluster"
  cluster_version = "1.29"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  enable_cluster_creator_admin_permissions = true

  cluster_encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn
    resources        = ["secrets"]
  }

  eks_managed_node_groups = {
    default = {
      instance_types = [var.eks_node_instance_type]
      capacity_type  = "SPOT"
      min_size       = 1
      max_size       = 3
      desired_size   = var.eks_node_count
    }
  }

  tags = {
    Project = var.prefix
  }
}

resource "aws_kms_key" "eks" {
  description             = "${var.prefix} EKS secret encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Project = var.prefix
  }
}

################################################################################
# Update local kubeconfig
################################################################################

resource "null_resource" "update_kubeconfig" {
  triggers = {
    cluster_name     = module.eks.cluster_name
    cluster_endpoint = module.eks.cluster_endpoint
  }

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
  }

  depends_on = [module.eks]
}

################################################################################
# Port-forward Grafana to localhost:3000
################################################################################

resource "null_resource" "grafana_port_forward" {
  triggers = {
    cluster_endpoint = module.eks.cluster_endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Kill any existing port-forward on 3000
      lsof -ti:3000 | xargs kill -9 2>/dev/null || true
      # Start port-forward in background
      nohup kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring > /dev/null 2>&1 &
      # Wait briefly and verify it started
      sleep 2
      if lsof -ti:3000 > /dev/null 2>&1; then
        echo "Grafana available at http://localhost:3000"
      else
        echo "WARNING: port-forward may not have started — run manually:"
        echo "  kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
      fi
    EOT
  }

  depends_on = [
    null_resource.update_kubeconfig,
    helm_release.kube_prometheus_stack,
  ]
}

################################################################################
# Port-forward Prometheus to localhost:9090
################################################################################

resource "null_resource" "prometheus_port_forward" {
  triggers = {
    cluster_endpoint = module.eks.cluster_endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Kill any existing port-forward on 9090
      lsof -ti:9090 | xargs kill -9 2>/dev/null || true
      # Start port-forward in background
      nohup kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring > /dev/null 2>&1 &
      # Wait briefly and verify it started
      sleep 2
      if lsof -ti:9090 > /dev/null 2>&1; then
        echo "Prometheus available at http://localhost:9090"
      else
        echo "WARNING: port-forward may not have started — run manually:"
        echo "  kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring"
      fi
    EOT
  }

  depends_on = [
    null_resource.update_kubeconfig,
    helm_release.kube_prometheus_stack,
  ]
}

################################################################################
# Port-forward Online Boutique frontend to localhost:8080
################################################################################

resource "null_resource" "boutique_frontend_port_forward" {
  triggers = {
    cluster_endpoint = module.eks.cluster_endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Kill any existing port-forward on 8080
      lsof -ti:8080 | xargs kill -9 2>/dev/null || true
      # Start port-forward in background
      nohup kubectl port-forward svc/frontend 8080:80 -n boutique > /dev/null 2>&1 &
      # Wait briefly and verify it started
      sleep 2
      if lsof -ti:8080 > /dev/null 2>&1; then
        echo "Online Boutique frontend available at http://localhost:8080"
      else
        echo "WARNING: port-forward may not have started — run manually:"
        echo "  kubectl port-forward svc/frontend 8080:80 -n boutique"
      fi
    EOT
  }

  depends_on = [
    null_resource.online_boutique,
  ]
}

################################################################################
# Kubernetes Namespaces
################################################################################

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [module.eks]
}

resource "kubernetes_namespace" "boutique" {
  metadata {
    name = "boutique"
  }

  depends_on = [module.eks]
}

################################################################################
# Helm Release: kube-prometheus-stack
################################################################################

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "65.1.0"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false
  timeout          = 600

  values = [yamlencode({
    grafana = {
      enabled       = true
      adminPassword = var.grafana_admin_password

      service = {
        type = "ClusterIP"
      }

      sidecar = {
        dashboards = {
          enabled         = true
          label           = "grafana_dashboard"
          labelValue      = "1"
          searchNamespace = "monitoring"
        }
      }

      additionalDataSources = [
        {
          name      = "Loki"
          type      = "loki"
          uid       = "loki"
          url       = "http://loki:3100"
          access    = "proxy"
          isDefault = false
          jsonData = {
            derivedFields = [
              {
                datasourceUid = "tempo"
                matcherRegex  = "(?:traceID|trace_id|TraceId)[=:]\\s*(\\w+)"
                name          = "TraceID"
                url           = "$${__value.raw}"
              }
            ]
          }
        },
        {
          name      = "Tempo"
          type      = "tempo"
          uid       = "tempo"
          url       = "http://tempo:3100"
          access    = "proxy"
          isDefault = false
          jsonData = {
            tracesToLogsV2 = {
              datasourceUid      = "loki"
              spanStartTimeShift = "-1h"
              spanEndTimeShift   = "1h"
              filterByTraceID    = true
              filterBySpanID     = false
              customQuery        = true
              query              = "{job=\"$${__span.tags[\"service.name\"]}\"}  |= `$${__span.traceId}`"
            }
            tracesToMetrics = {
              datasourceUid = "prometheus"
            }
            serviceMap = {
              datasourceUid = "prometheus"
            }
            nodeGraph = {
              enabled = true
            }
            lokiSearch = {
              datasourceUid = "loki"
            }
          }
        }
      ]
    }

    prometheus = {
      prometheusSpec = {
        retention                               = "7d"
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        enableRemoteWriteReceiver               = true
      }
    }

    alertmanager = {
      enabled = true
    }

    additionalPrometheusRulesMap = {
      custom-alerts = {
        groups = [
          {
            name = "custom-alerts"
            rules = [
              {
                alert = "PodCrashLooping"
                expr  = "increase(kube_pod_container_status_restarts_total[5m]) > 3"
                for   = "1m"
                labels = {
                  severity = "warning"
                }
                annotations = {
                  summary     = "Pod {{ $labels.namespace }}/{{ $labels.pod }} is crash looping"
                  description = "Pod {{ $labels.namespace }}/{{ $labels.pod }} has restarted {{ $value }} times in the last 5 minutes."
                }
              },
              {
                alert = "HighErrorRate"
                expr  = "sum(rate(http_server_requests_seconds_count{status=~\"5..\"}[2m])) by (service) / sum(rate(http_server_requests_seconds_count[2m])) by (service) > 0.05"
                for   = "2m"
                labels = {
                  severity = "critical"
                }
                annotations = {
                  summary     = "High HTTP 5xx error rate on {{ $labels.service }}"
                  description = "Service {{ $labels.service }} has a 5xx error rate above 5% for the last 2 minutes."
                }
              },
              {
                alert = "HighLatency"
                expr  = "histogram_quantile(0.99, sum(rate(http_server_requests_seconds_bucket[5m])) by (le, service)) > 2"
                for   = "5m"
                labels = {
                  severity = "warning"
                }
                annotations = {
                  summary     = "High p99 latency on {{ $labels.service }}"
                  description = "Service {{ $labels.service }} p99 latency is above 2s for the last 5 minutes."
                }
              },
              {
                alert = "NodeNotReady"
                expr  = "kube_node_status_condition{condition=\"Ready\",status=\"true\"} == 0"
                for   = "2m"
                labels = {
                  severity = "critical"
                }
                annotations = {
                  summary     = "Node {{ $labels.node }} is not Ready"
                  description = "Node {{ $labels.node }} has been in a non-Ready state for more than 2 minutes."
                }
              },
              {
                alert = "PodPending"
                expr  = "kube_pod_status_phase{phase=\"Pending\"} == 1"
                for   = "5m"
                labels = {
                  severity = "warning"
                }
                annotations = {
                  summary     = "Pod {{ $labels.namespace }}/{{ $labels.pod }} stuck in Pending"
                  description = "Pod {{ $labels.namespace }}/{{ $labels.pod }} has been in Pending state for more than 5 minutes."
                }
              }
            ]
          }
        ]
      }
    }
  })]

  depends_on = [module.eks]
}

################################################################################
# Helm Release: Loki Stack
################################################################################

resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki-stack"
  version          = "2.10.2"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false
  timeout          = 600

  values = [yamlencode({
    loki = {
      enabled = true
      persistence = {
        enabled = false
      }
    }
    promtail = {
      enabled = true
    }
  })]

  depends_on = [module.eks]
}

################################################################################
# Helm Release: Tempo
################################################################################

resource "helm_release" "tempo" {
  name             = "tempo"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "tempo"
  version          = "1.10.3"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false
  timeout          = 600

  values = [yamlencode({
    tempo = {
      receivers = {
        otlp = {
          protocols = {
            grpc = {
              endpoint = "0.0.0.0:4317"
            }
            http = {
              endpoint = "0.0.0.0:4318"
            }
          }
        }
      }
      metricsGenerator = {
        enabled        = true
        remoteWriteUrl = "http://kube-prometheus-stack-prometheus:9090/api/v1/write"
        processor = {
          service_graphs = {}
          span_metrics   = {}
        }
      }
    }
    service = {
      type = "ClusterIP"
    }
  })]

  depends_on = [module.eks]
}

################################################################################
# Helm Release: OpenTelemetry Collector
################################################################################

resource "helm_release" "otel_collector" {
  name             = "otel-collector"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-collector"
  version          = "0.73.1"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false
  timeout          = 600

  values = [yamlencode({
    mode = "daemonset"

    config = {
      receivers = {
        otlp = {
          protocols = {
            grpc = {
              endpoint = "0.0.0.0:4317"
            }
            http = {
              endpoint = "0.0.0.0:4318"
            }
          }
        }
      }
      processors = {
        batch = {}
        resourcedetection = {
          detectors = ["env", "system"]
          timeout   = "5s"
          override  = false
        }
      }
      exporters = {
        otlp = {
          endpoint = "tempo.monitoring.svc.cluster.local:4317"
          tls = {
            # Cluster-internal traffic only — no sensitive data in trace payloads
            insecure = true
          }
        }
      }
      service = {
        pipelines = {
          traces = {
            receivers  = ["otlp"]
            processors = ["resourcedetection", "batch"]
            exporters  = ["otlp"]
          }
        }
      }
    }

    ports = {
      otlp = {
        enabled       = true
        containerPort = 4317
        servicePort   = 4317
        protocol      = "TCP"
      }
      otlp-http = {
        enabled       = true
        containerPort = 4318
        servicePort   = 4318
        protocol      = "TCP"
      }
    }
  })]

  depends_on = [module.eks]
}

################################################################################
# Deploy Online Boutique (raw manifests — Helm OCI registry was deleted)
################################################################################

resource "null_resource" "online_boutique" {
  triggers = {
    cluster_endpoint = module.eks.cluster_endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/main/release/kubernetes-manifests.yaml -n boutique

      echo "Patching boutique deployments with OTel collector endpoint..."
      TRACED_SERVICES="checkoutservice currencyservice emailservice frontend paymentservice productcatalogservice recommendationservice"
      for svc in $TRACED_SERVICES; do
        kubectl set env deployment/$svc -n boutique \
          COLLECTOR_SERVICE_ADDR="tempo.monitoring:4317" \
          OTEL_SERVICE_NAME="$svc" \
          ENABLE_TRACING=1
      done

      echo "Waiting for Online Boutique pods to be ready..."
      kubectl wait --for=condition=ready pod -l app=frontend -n boutique --timeout=300s
    EOT
  }

  depends_on = [
    null_resource.update_kubeconfig,
    kubernetes_namespace.boutique,
    helm_release.otel_collector,
  ]
}

################################################################################
# Dashboard ConfigMaps
################################################################################

locals {
  dashboards = {
    "kubernetes-cluster-overview" = "kubernetes-cluster-overview.json"
    "node-exporter"               = "node-exporter.json"
    "pod-overview"                = "pod-overview.json"
    "loki-log-explorer"           = "loki-log-explorer.json"
    "tempo-trace-explorer"        = "tempo-trace-explorer.json"
    "red-golden-signals"          = "red-golden-signals.json"
    "service-dependency-map"      = "service-dependency-map.json"
  }
}

resource "kubernetes_config_map" "grafana_dashboards" {
  for_each = local.dashboards

  metadata {
    name      = "grafana-dashboard-${each.key}"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "${each.value}" = file("${path.module}/../config/dashboards/${each.value}")
  }

  depends_on = [module.eks]
}
