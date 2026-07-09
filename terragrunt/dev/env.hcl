# dev environment — small, cheap, 2 AZs, single shared NAT.
locals {
  environment  = "dev"
  account_id   = "111111111111" # placeholder — set to the real dev account id
  region       = "us-east-1"
  cluster_name = "aequor-dev"

  vpc_cidr        = "10.10.0.0/16"
  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.10.0.0/20", "10.10.16.0/20"]
  public_subnets  = ["10.10.128.0/24", "10.10.129.0/24"]
}
