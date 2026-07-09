include "root" {
  path = find_in_parent_folders()
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders())}/_envcommon/eks.hcl"
  merge_strategy = "deep"
}

# prod overrides: HA NAT per AZ, larger on-demand system group, deletion protection,
# and a locked-down public API endpoint (replace with your office/VPN CIDRs).
inputs = {
  single_nat_gateway         = false
  enable_deletion_protection = true
  public_access_cidrs        = ["10.0.0.0/8"] # placeholder: corporate egress only
  node_group = {
    instance_types = ["m6i.large"]
    min_size       = 3
    max_size       = 6
    desired_size   = 3
    capacity_type  = "ON_DEMAND"
  }
}
