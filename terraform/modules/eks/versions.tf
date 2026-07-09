# Provider + Terraform version constraints for the EKS platform module.
# Pinned deliberately (see CLAUDE.md working agreement: no blind version bumps).
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    # Used by the community EKS module to bootstrap aws-auth / access entries
    # and to template kubeconfig-free auth for the addons layer.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
