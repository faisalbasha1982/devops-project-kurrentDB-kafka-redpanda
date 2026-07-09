include "root" {
  path = find_in_parent_folders()
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders())}/_envcommon/eks.hcl"
  merge_strategy = "deep"
}

# dev overrides: cheap single NAT, tiny system node group, no deletion protection.
inputs = {
  single_nat_gateway         = true
  enable_deletion_protection = false
  node_group = {
    instance_types = ["t3.large"]
    min_size       = 1
    max_size       = 3
    desired_size   = 2
    capacity_type  = "SPOT"
  }
}
