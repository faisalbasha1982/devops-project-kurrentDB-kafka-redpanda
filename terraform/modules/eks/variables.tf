variable "cluster_name" {
  description = "EKS cluster name. Also used as the Karpenter/subnet discovery tag value."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes control-plane version."
  type        = string
  default     = "1.31"
}

variable "region" {
  description = "AWS region (informational for this module; provider region is set by the caller)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread subnets across. Prod uses 3, dev uses 2."
  type        = list(string)
}

variable "private_subnets" {
  description = "Private subnet CIDRs (one per AZ). EKS nodes + pods live here."
  type        = list(string)
}

variable "public_subnets" {
  description = "Public subnet CIDRs (one per AZ). Only for internet-facing LBs + NAT."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "true = one shared NAT GW (cheap, dev). false = one per AZ (HA, prod)."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access" {
  description = "Expose the API server publicly. Keep true for CI/kubectl; lock down CIDRs in prod."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_group" {
  description = <<-EOT
    The small managed node group that hosts system add-ons (CoreDNS, Karpenter
    controller, ALB controller). App workloads run on Karpenter-provisioned
    capacity, not here.
  EOT
  type = object({
    instance_types = list(string)
    min_size       = number
    max_size       = number
    desired_size   = number
    capacity_type  = optional(string, "ON_DEMAND")
  })
  default = {
    instance_types = ["m6i.large"]
    min_size       = 2
    max_size       = 4
    desired_size   = 2
  }
}

variable "enable_deletion_protection" {
  description = "Prod safety: guards the cluster + its state from accidental teardown."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
