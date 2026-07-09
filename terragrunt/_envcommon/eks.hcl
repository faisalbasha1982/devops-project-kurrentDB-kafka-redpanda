# Shared definition for the vpc-eks unit. dev/prod include this and layer on
# env-specific sizing (AZ count, NAT strategy, node group size).

terraform {
  # get_terragrunt_dir() resolves to the *consuming* unit dir at runtime, so the
  # relative hop is identical for every env/<unit>.
  source = "${get_terragrunt_dir()}/../../../terraform//modules/eks"
}

# env.hcl locals are available to the including unit; re-read here for defaults.
locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  cluster_name    = local.env_vars.locals.cluster_name
  cluster_version = "1.31"
  region          = local.env_vars.locals.region
  vpc_cidr        = local.env_vars.locals.vpc_cidr
  azs             = local.env_vars.locals.azs
  private_subnets = local.env_vars.locals.private_subnets
  public_subnets  = local.env_vars.locals.public_subnets
}
