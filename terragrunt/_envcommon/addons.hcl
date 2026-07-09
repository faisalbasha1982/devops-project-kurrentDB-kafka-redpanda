# Shared definition for the addons unit: IRSA example roles + LB controller +
# the KurrentDB cold-archive S3 bucket. Depends on the vpc-eks unit.

terraform {
  source = "${get_terragrunt_dir()}/../../../terraform//modules/addons"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

dependency "vpc_eks" {
  config_path = "../vpc-eks"

  mock_outputs = {
    cluster_name                       = "aequor-mock"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "bW9jaw==" # base64("mock")
    oidc_provider_arn                  = "arn:aws:iam::000000000000:oidc-provider/mock"
    vpc_id                             = "vpc-000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

# addons installs the AWS LB Controller via Helm -> needs a helm provider.
generate "k8s_providers" {
  path      = "k8s_providers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "helm" {
      kubernetes {
        host                   = "${dependency.vpc_eks.outputs.cluster_endpoint}"
        cluster_ca_certificate = base64decode("${dependency.vpc_eks.outputs.cluster_certificate_authority_data}")
        exec {
          api_version = "client.authentication.k8s.io/v1beta1"
          command     = "aws"
          args        = ["eks", "get-token", "--cluster-name", "${local.env_vars.locals.cluster_name}", "--region", "${local.env_vars.locals.region}"]
        }
      }
    }
  EOF
}

inputs = {
  cluster_name      = dependency.vpc_eks.outputs.cluster_name
  oidc_provider_arn = dependency.vpc_eks.outputs.oidc_provider_arn
  vpc_id            = dependency.vpc_eks.outputs.vpc_id
  region            = local.env_vars.locals.region
  # Bucket name must be globally unique -> suffix with account id + env.
  archive_bucket_name = "aequor-kurrentdb-archive-${local.env_vars.locals.account_id}-${local.env_vars.locals.environment}"
  app_namespace       = "aequor"
}
