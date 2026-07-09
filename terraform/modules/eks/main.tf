# -----------------------------------------------------------------------------
# Aequor EKS platform module.
#
# Thin, opinionated wrapper over the upstream community VPC + EKS modules. We do
# NOT hand-roll VPC/EKS resources (CLAUDE.md: favor community modules, keep the
# footprint small). This module produces: a private-subnet VPC, an EKS cluster
# with the OIDC provider enabled (so IRSA works), and a *small* managed node
# group for system add-ons. App autoscaling is Karpenter's job (separate module).
# -----------------------------------------------------------------------------

locals {
  # Karpenter and the AWS LB controller discover subnets/SGs by this tag.
  discovery_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway = true
  # dev: single shared NAT (cheap). prod: one per AZ (no cross-AZ SPOF).
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway
  enable_dns_hostnames   = true

  # ELB/subnet auto-discovery tags. Internal LBs land on private subnets,
  # internet-facing LBs on public subnets, and Karpenter finds private subnets.
  private_subnet_tags = merge(local.discovery_tags, {
    "kubernetes.io/role/internal-elb" = "1"
  })
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  tags = var.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # IRSA: create the IAM OIDC provider so ServiceAccounts can assume IAM roles.
  # (v20 enables this by default; set explicitly so the intent is obvious.)
  enable_irsa = true

  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.public_access_cidrs
  cluster_endpoint_private_access      = true

  # API-based access entries (v20 default), plus grant the Terraform principal
  # cluster-admin so the addons layer can install controllers right after apply.
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # Core add-ons managed by EKS itself. Karpenter runs on the managed node
  # group, so CoreDNS/kube-proxy must be up before app nodes exist.
  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true }
  }

  eks_managed_node_groups = {
    system = {
      instance_types = var.node_group.instance_types
      capacity_type  = var.node_group.capacity_type
      min_size       = var.node_group.min_size
      max_size       = var.node_group.max_size
      desired_size   = var.node_group.desired_size

      # Keep app pods off the system group; Karpenter nodes are untainted.
      labels = { "aequor.io/pool" = "system" }
    }
  }

  # Tag cluster SGs for Karpenter discovery.
  node_security_group_tags = local.discovery_tags

  # NB: EKS clusters have no native "deletion protection" flag (unlike RDS).
  # We surface the intent as a tag and enforce it operationally via the remote
  # backend (prod state is a separate, restricted S3 prefix — see terraform/README.md).
  tags = merge(var.tags, {
    "aequor.io/deletion-protection" = tostring(var.enable_deletion_protection)
  })
}
