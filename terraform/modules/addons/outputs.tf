output "app_role_arn" {
  description = "IRSA role ARN for settlement + rebuild (S3 chunk archive access)."
  value       = module.app_role.role_arn
}

output "lb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller."
  value       = module.lb_controller_role.role_arn
}

output "external_dns_role_arn" {
  description = "IRSA role ARN for external-dns (null unless enabled)."
  value       = var.enable_external_dns ? module.external_dns_role[0].role_arn : null
}

output "archive_bucket_arn" {
  description = "ARN of the KurrentDB chunk cold-archive bucket."
  value       = aws_s3_bucket.kurrentdb_archive.arn
}
