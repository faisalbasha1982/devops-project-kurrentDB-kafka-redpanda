# Shared definition for the karpenter unit. Depends on the vpc-eks unit's
# outputs (cluster endpoint + OIDC provider), so `run-all apply` orders it after.

terraform {
  source = "${get_terragrunt_dir()}/../../../terraform//modules/karpenter"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

dependency "vpc_eks" {
  config_path = "../vpc-eks"

  # Lets `plan`/`validate` run before the cluster exists (CI + first apply).
  mock_outputs = {
    cluster_name                       = "aequor-mock"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "bW9jaw==" # base64("mock")
    oidc_provider_arn                  = "arn:aws:iam::000000000000:oidc-provider/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

# helm + kubectl talk to the cluster vpc-eks created. Generated here (not in the
# root) because only units with a vpc_eks dependency have these values.
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

    provider "kubectl" {
      host                   = "${dependency.vpc_eks.outputs.cluster_endpoint}"
      cluster_ca_certificate = base64decode("${dependency.vpc_eks.outputs.cluster_certificate_authority_data}")
      load_config_file       = false
      exec {
        api_version = "client.authentication.k8s.io/v1beta1"
        command     = "aws"
        args        = ["eks", "get-token", "--cluster-name", "${local.env_vars.locals.cluster_name}", "--region", "${local.env_vars.locals.region}"]
      }
    }
  EOF
}

inputs = {
  cluster_name      = dependency.vpc_eks.outputs.cluster_name
  cluster_endpoint  = dependency.vpc_eks.outputs.cluster_endpoint
  oidc_provider_arn = dependency.vpc_eks.outputs.oidc_provider_arn
}
