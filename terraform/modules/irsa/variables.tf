variable "role_name" {
  description = "Name of the IAM role to create."
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS IAM OIDC provider ARN (from the eks module)."
  type        = string
}

variable "namespace_service_accounts" {
  description = <<-EOT
    List of "<namespace>:<serviceaccount>" the role may be assumed by.
    Each maps to a StringLike condition on the OIDC `sub` claim, so a single
    role can back one SA (usual) or several (e.g. settlement + rebuild).
  EOT
  type        = list(string)
}

variable "policy_arns" {
  description = "Managed policy ARNs to attach (e.g. an AWS-managed controller policy)."
  type        = list(string)
  default     = []
}

variable "inline_policy_json" {
  description = "Optional inline policy document (JSON). Null = no inline policy."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the role."
  type        = map(string)
  default     = {}
}
