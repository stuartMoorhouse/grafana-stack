# Grafana Observability Stack on EKS

Google Online Boutique microservices demo on AWS EKS, fully observed with the Grafana LGTM stack (Loki, Grafana, Tempo, Prometheus).

## Architecture

- **EKS cluster** with 2x t3.medium managed nodes (us-east-1)
- **Online Boutique** -- 11 microservices with OpenTelemetry instrumentation in `boutique` namespace
- **Monitoring stack** in `monitoring` namespace:
  - Prometheus (kube-prometheus-stack) -- metrics + alerting
  - Loki + Promtail -- log aggregation
  - Tempo -- distributed tracing
  - OpenTelemetry Collector -- trace pipeline
  - Grafana -- dashboards, data source correlation

## Pre-built Dashboards

- Kubernetes Cluster Overview
- Node Exporter
- Pod Overview
- Loki Log Explorer
- Tempo Trace Explorer
- RED / Golden Signals per service
- Service Dependency Map

## Quick Start

```bash
# Deploy — set the Grafana admin credential via TF_VAR environment variable first
cd infra
terraform init
terraform apply

# Connect
aws eks update-kubeconfig --name grafana-demo-cluster --region us-east-1

# Deploy Online Boutique (OCI chart registry is defunct)
kubectl apply -f release/kubernetes-manifests.yaml -n boutique

# Access Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
```

## Teardown

```bash
./scripts/teardown.sh
```
