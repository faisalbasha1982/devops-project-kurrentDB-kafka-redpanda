output "controller_iam_role_arn" {
  description = "IRSA role assumed by the Karpenter controller ServiceAccount."
  value       = module.karpenter.iam_role_arn
}

output "node_iam_role_name" {
  description = "IAM role attached to Karpenter-launched nodes (referenced by EC2NodeClass)."
  value       = module.karpenter.node_iam_role_name
}

output "interruption_queue_name" {
  description = "SQS queue Karpenter watches for spot interruption / rebalance events."
  value       = module.karpenter.queue_name
}
