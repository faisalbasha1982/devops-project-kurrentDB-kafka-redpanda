# =============================================================================
# Aequor — root Terragrunt config (DRY across dev/prod).
#
# Every unit `include`s this. It provides:
#   * S3 remote state + DynamoDB lock (one state key per unit per env)
#   * generated provider.tf (aws + aliased us-east-1 aws + helm + kubectl)
#   * generated versions.tf (pinned)
#   * common inputs merged from the env's env.hcl
# =============================================================================

locals {
  # Load env.hcl from the nearest environment directory (dev/ or prod/).
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))

  account_id   = local.env_vars.locals.account_id
  region       = local.env_vars.locals.region
  environment  = local.env_vars.locals.environment
  cluster_name = local.env_vars.locals.cluster_name

  state_bucket = "aequor-tfstate-${local.account_id}"
  lock_table   = "aequor-tflock"
}

# --- remote state -----------------------------------------------------------
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = local.state_bucket
    key            = "${local.environment}/${path_relative_to_include()}/terraform.tfstate"
    region         = local.region
    encrypt        = true
    dynamodb_table = local.lock_table
  }
}

# --- providers (generated) --------------------------------------------------
# Only the AWS providers are shared by every unit. The helm + kubectl providers
# need the cluster endpoint/CA, which only exist AFTER vpc-eks applies, so units
# that talk to Kubernetes (karpenter, addons) generate those themselves from
# their `dependency.vpc_eks` outputs (see _envcommon/{karpenter,addons}.hcl).
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region = "${local.region}"
      default_tags {
        tags = {
          "aequor.io/env"        = "${local.environment}"
          "aequor.io/managed-by" = "terragrunt"
        }
      }
    }

    # Karpenter's chart lives in ECR Public (tokens only issued in us-east-1).
    provider "aws" {
      alias  = "us_east_1"
      region = "us-east-1"
    }
  EOF
}

# NB: provider *version* pins live in each module's own versions.tf (eks,
# karpenter, irsa, addons). We deliberately do NOT generate a required_providers
# block here — that would collide with the module's block ("Duplicate required
# providers configuration"). The generated provider.tf above only supplies
# provider *configuration* (regions, default tags, ECR-public alias).

# Inputs common to every unit; env.hcl and each unit layer more on top.
inputs = {
  region       = local.region
  cluster_name = local.cluster_name
  tags = {
    "aequor.io/env" = local.environment
  }
}
