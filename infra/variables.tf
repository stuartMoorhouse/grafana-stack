variable "region" {
  description = "Vultr region slug (e.g. ewr, ord, lax, ams)"
  type        = string
  default     = "ewr"
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "grafana-demo"
}

variable "grafana_admin_password" {
  description = "Admin password for Grafana"
  type        = string
  sensitive   = true
  default     = "admin"
}

variable "vke_version" {
  description = "Kubernetes version for VKE (check: curl -H 'Authorization: Bearer $VULTR_API_KEY' https://api.vultr.com/v2/kubernetes/versions)"
  type        = string
  default     = "v1.32.9+3"
}

variable "node_plan" {
  description = "Vultr compute plan for VKE nodes (e.g. vc2-2c-4gb, vc2-4c-8gb)"
  type        = string
  default     = "vc2-2c-4gb"
}

variable "node_count" {
  description = "Desired number of VKE worker nodes"
  type        = number
  default     = 2
}
