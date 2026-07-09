terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
      # ECR Public auth tokens are only issued in us-east-1, so this module
      # needs a second, aliased AWS provider the caller must pass in.
      configuration_aliases = [aws.us_east_1]
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    # gavinbunney/kubectl applies raw CRs (NodePool/EC2NodeClass) whose CRDs are
    # installed by the Karpenter Helm chart in the same apply.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
