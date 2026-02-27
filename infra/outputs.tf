output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Command to update kubeconfig for this cluster"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "my_public_ip" {
  description = "Detected public IP used for access restriction"
  value       = local.my_ip_cidr
}

output "grafana_url" {
  description = "Grafana UI URL (LoadBalancer)"
  value       = "http://${try(data.kubernetes_service.grafana.status[0].load_balancer[0].ingress[0].hostname, "pending...")}"
}

output "prometheus_url" {
  description = "Prometheus UI URL (LoadBalancer)"
  value       = "http://${try(data.kubernetes_service.prometheus.status[0].load_balancer[0].ingress[0].hostname, "pending...")}:9090"
}

output "boutique_url" {
  description = "Online Boutique frontend URL (LoadBalancer)"
  value       = "http://${try(data.kubernetes_service.boutique_frontend.status[0].load_balancer[0].ingress[0].hostname, "pending...")}"
}

output "service_urls" {
  description = "All service URLs"
  value       = <<-EOT
    Grafana:        http://${try(data.kubernetes_service.grafana.status[0].load_balancer[0].ingress[0].hostname, "pending...")}
    Prometheus:     http://${try(data.kubernetes_service.prometheus.status[0].load_balancer[0].ingress[0].hostname, "pending...")}:9090
    Online Boutique: http://${try(data.kubernetes_service.boutique_frontend.status[0].load_balancer[0].ingress[0].hostname, "pending...")}
  EOT
}
