variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS IAM OIDC provider ARN (from the eks module)."
  type        = string
}

variable "vpc_id" {
  description = "VPC id (the AWS LB controller needs it)."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "archive_bucket_name" {
  description = <<-EOT
    S3 bucket for KurrentDB chunk cold-archiving (Phase 2d DR). settlement +
    rebuild get scoped read/write here via IRSA. Must be globally unique.
  EOT
  type        = string
}

variable "app_namespace" {
  description = "Kubernetes namespace the Aequor app services run in."
  type        = string
  default     = "aequor"
}

variable "enable_external_dns" {
  description = "Optional: create the external-dns IRSA role + Route53 policy."
  type        = bool
  default     = false
}

variable "route53_zone_arn" {
  description = "Route53 hosted-zone ARN external-dns may manage (required if enabled)."
  type        = string
  default     = "*"
}

variable "install_aws_lb_controller" {
  description = "Install the AWS Load Balancer Controller Helm chart (needs cluster access)."
  type        = bool
  default     = true
}

variable "aws_lb_controller_chart_version" {
  description = "aws-load-balancer-controller Helm chart version."
  type        = string
  default     = "1.8.2"
}

variable "tags" {
  description = "Tags applied to created resources."
  type        = map(string)
  default     = {}
}
