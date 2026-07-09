variable "cluster_name" {
  description = "EKS cluster name (also the subnet/SG discovery tag value)."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS API endpoint (passed to the Karpenter controller)."
  type        = string
}

variable "oidc_provider_arn" {
  description = "IAM OIDC provider ARN from the eks module — anchors the controller IRSA role."
  type        = string
}

variable "karpenter_chart_version" {
  description = "Karpenter Helm chart version (OCI public.ecr.aws/karpenter/karpenter)."
  type        = string
  default     = "1.0.6"
}

variable "instance_categories" {
  description = "EC2 instance categories Karpenter may pick from."
  type        = list(string)
  default     = ["c", "m", "r"]
}

variable "capacity_types" {
  description = "Order matters only for readability; Karpenter prefers spot then falls back to on-demand."
  type        = list(string)
  default     = ["spot", "on-demand"]
}

variable "cpu_limit" {
  description = "Cluster-wide vCPU ceiling for Karpenter-managed capacity (cost guardrail)."
  type        = number
  default     = 100
}

variable "tags" {
  description = "Tags applied to Karpenter IAM resources."
  type        = map(string)
  default     = {}
}
