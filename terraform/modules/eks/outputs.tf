output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA cert for the cluster (for kubeconfig / providers)."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_version" {
  description = "Kubernetes version actually running."
  value       = module.eks.cluster_version
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN — the anchor for all IRSA trust policies."
  value       = module.eks.oidc_provider_arn
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL (https://oidc.eks...). Terratest asserts this is set."
  value       = module.eks.cluster_oidc_issuer_url
}

output "node_security_group_id" {
  description = "Shared node SG id — Karpenter EC2NodeClass discovers it by tag."
  value       = module.eks.node_security_group_id
}

output "vpc_id" {
  description = "VPC id."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet ids (Karpenter provisions nodes here)."
  value       = module.vpc.private_subnets
}
