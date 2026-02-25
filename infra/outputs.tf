output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "grafana_port_forward_command" {
  description = "Command to port-forward Grafana to localhost:3000"
  value       = "kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
}

output "prometheus_port_forward_command" {
  description = "Command to port-forward Prometheus to localhost:9090"
  value       = "kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring"
}

output "kubeconfig_command" {
  description = "Command to update kubeconfig for this cluster"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "port_forwards" {
  description = "Active port-forwards"
  value       = <<-EOT
    Grafana UI:    http://localhost:3000
    Prometheus UI: http://localhost:9090
  EOT
}
