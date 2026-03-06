output "cluster_id" {
  description = "VKE cluster ID"
  value       = vultr_kubernetes.cluster.id
}

output "cluster_endpoint" {
  description = "VKE cluster API endpoint"
  value       = vultr_kubernetes.cluster.endpoint
}

output "cluster_ip" {
  description = "VKE cluster IP"
  value       = vultr_kubernetes.cluster.ip
}

output "kubeconfig_path" {
  description = "Path to kubeconfig file"
  value       = abspath(local_sensitive_file.kubeconfig.filename)
}

output "region" {
  description = "Vultr region"
  value       = var.region
}

output "my_public_ip" {
  description = "Detected public IP used for access restriction"
  value       = local.my_ip_cidr
}

output "grafana_url" {
  description = "Grafana UI URL (LoadBalancer)"
  value       = "http://${try(data.kubernetes_service.grafana.status[0].load_balancer[0].ingress[0].ip, "pending...")}"
}

output "prometheus_url" {
  description = "Prometheus UI URL (LoadBalancer)"
  value       = "http://${try(data.kubernetes_service.prometheus.status[0].load_balancer[0].ingress[0].ip, "pending...")}:9090"
}

output "boutique_url" {
  description = "Online Boutique frontend URL (LoadBalancer)"
  value       = "http://${try(data.kubernetes_service.boutique_frontend.status[0].load_balancer[0].ingress[0].ip, "pending...")}"
}

output "service_urls" {
  description = "All service URLs"
  value       = <<-EOT
    Grafana:         http://${try(data.kubernetes_service.grafana.status[0].load_balancer[0].ingress[0].ip, "pending...")}
    Prometheus:      http://${try(data.kubernetes_service.prometheus.status[0].load_balancer[0].ingress[0].ip, "pending...")}:9090
    Online Boutique: http://${try(data.kubernetes_service.boutique_frontend.status[0].load_balancer[0].ingress[0].ip, "pending...")}
  EOT
}
