################################################################################
# Terraform & Provider Configuration
################################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.0"
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
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

provider "vultr" {
  # Uses VULTR_API_KEY environment variable
}

provider "kubernetes" {
  host                   = "https://${vultr_kubernetes.cluster.endpoint}:6443"
  cluster_ca_certificate = base64decode(vultr_kubernetes.cluster.cluster_ca_certificate)
  client_certificate     = base64decode(vultr_kubernetes.cluster.client_certificate)
  client_key             = base64decode(vultr_kubernetes.cluster.client_key)
}

provider "helm" {
  kubernetes {
    host                   = "https://${vultr_kubernetes.cluster.endpoint}:6443"
    cluster_ca_certificate = base64decode(vultr_kubernetes.cluster.cluster_ca_certificate)
    client_certificate     = base64decode(vultr_kubernetes.cluster.client_certificate)
    client_key             = base64decode(vultr_kubernetes.cluster.client_key)
  }
}

################################################################################
# Data Sources
################################################################################

data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  my_ip_cidr = "${trimspace(data.http.my_ip.response_body)}/32"
}

################################################################################
# VKE Cluster
################################################################################

resource "vultr_kubernetes" "cluster" {
  region  = var.region
  label   = "${var.prefix}-cluster"
  version = var.vke_version

  node_pools {
    node_quantity = var.node_count
    plan          = var.node_plan
    label         = "default"
    auto_scaler   = true
    min_nodes     = 1
    max_nodes     = 3
  }
}

################################################################################
# Wait for VKE API server to accept connections
################################################################################

resource "time_sleep" "wait_for_api" {
  depends_on      = [vultr_kubernetes.cluster]
  create_duration = "60s"
}

################################################################################
# Write kubeconfig for kubectl access
################################################################################

resource "local_sensitive_file" "kubeconfig" {
  content         = base64decode(vultr_kubernetes.cluster.kube_config)
  filename        = "${path.module}/kubeconfig"
  file_permission = "0600"
  depends_on      = [time_sleep.wait_for_api]
}

################################################################################
# Merge kubeconfig into ~/.kube/config and set active context
################################################################################

resource "null_resource" "kubectl_config" {
  depends_on = [local_sensitive_file.kubeconfig]

  triggers = {
    cluster_id = vultr_kubernetes.cluster.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Backup existing kubeconfig
      [ -f "$HOME/.kube/config" ] && cp "$HOME/.kube/config" "$HOME/.kube/config.bak"

      # Merge Vultr kubeconfig into ~/.kube/config
      mkdir -p "$HOME/.kube"
      KUBECONFIG="${path.module}/kubeconfig:$HOME/.kube/config" \
        kubectl config view --flatten > "$HOME/.kube/config.merged"
      mv "$HOME/.kube/config.merged" "$HOME/.kube/config"
      chmod 600 "$HOME/.kube/config"

      # Set active context to Vultr cluster
      VULTR_CTX=$(kubectl --kubeconfig="${path.module}/kubeconfig" config current-context)
      kubectl config use-context "$VULTR_CTX"

      echo "kubectl configured for Vultr VKE cluster"
      kubectl cluster-info
    EOT
  }
}

################################################################################
# Patch Online Boutique frontend to LoadBalancer
################################################################################

resource "null_resource" "boutique_frontend_lb" {
  triggers = {
    my_ip_cidr = local.my_ip_cidr
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = abspath(local_sensitive_file.kubeconfig.filename)
    }
    command = <<-EOT
      kubectl patch svc frontend -n boutique -p '{"spec":{"type":"ClusterIP"}}' --type=merge
      kubectl patch svc frontend-external -n boutique -p '{"spec":{"loadBalancerSourceRanges":["${local.my_ip_cidr}"]}}'
      echo "Waiting for frontend-external LoadBalancer IP..."
      for i in $(seq 1 30); do
        IP=$(kubectl get svc frontend-external -n boutique -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        if [ -n "$IP" ]; then
          echo "Online Boutique: http://$IP"
          break
        fi
        sleep 10
      done
    EOT
  }

  depends_on = [
    local_sensitive_file.kubeconfig,
    null_resource.online_boutique,
  ]
}

################################################################################
# Read LoadBalancer IPs for outputs
################################################################################

data "kubernetes_service" "grafana" {
  metadata {
    name      = "kube-prometheus-stack-grafana"
    namespace = "monitoring"
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

data "kubernetes_service" "prometheus" {
  metadata {
    name      = "kube-prometheus-stack-prometheus"
    namespace = "monitoring"
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

data "kubernetes_service" "boutique_frontend" {
  metadata {
    name      = "frontend-external"
    namespace = "boutique"
  }

  depends_on = [null_resource.boutique_frontend_lb]
}

################################################################################
# Kubernetes Namespaces
################################################################################

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [time_sleep.wait_for_api]
}

resource "kubernetes_namespace" "boutique" {
  metadata {
    name = "boutique"
  }

  depends_on = [time_sleep.wait_for_api]
}

################################################################################
# Helm Release: kube-prometheus-stack
################################################################################

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "70.0.0"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false
  timeout          = 600

  values = [yamlencode({
    grafana = {
      enabled       = true
      adminPassword = var.grafana_admin_password

      image = {
        tag = "12.3.4"
      }

      service = {
        type                     = "LoadBalancer"
        loadBalancerSourceRanges = [local.my_ip_cidr]
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
      service = {
        type                     = "LoadBalancer"
        loadBalancerSourceRanges = [local.my_ip_cidr]
      }
      prometheusSpec = {
        retention                               = "7d"
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        enableRemoteWriteReceiver               = true
      }
    }

    # VKE control plane components are managed by Vultr and not exposed for scraping
    kubeControllerManager = {
      enabled = false
    }
    kubeEtcd = {
      enabled = false
    }
    kubeScheduler = {
      enabled = false
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

  depends_on = [time_sleep.wait_for_api]
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

  depends_on = [time_sleep.wait_for_api]
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

  depends_on = [time_sleep.wait_for_api]
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

  depends_on = [time_sleep.wait_for_api]
}

################################################################################
# Deploy Online Boutique (raw manifests — Helm OCI registry was deleted)
################################################################################

resource "null_resource" "online_boutique" {
  triggers = {
    cluster_id = vultr_kubernetes.cluster.id
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = abspath(local_sensitive_file.kubeconfig.filename)
    }
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
    local_sensitive_file.kubeconfig,
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

  depends_on = [time_sleep.wait_for_api]
}
