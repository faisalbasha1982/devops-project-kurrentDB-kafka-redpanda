# prod environment — larger, multi-AZ (3), one NAT per AZ, deletion protection.
locals {
  environment  = "prod"
  account_id   = "222222222222" # placeholder — set to the real prod account id
  region       = "us-east-1"
  cluster_name = "aequor-prod"

  vpc_cidr        = "10.20.0.0/16"
  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.20.0.0/20", "10.20.16.0/20", "10.20.32.0/20"]
  public_subnets  = ["10.20.128.0/24", "10.20.129.0/24", "10.20.130.0/24"]
}
