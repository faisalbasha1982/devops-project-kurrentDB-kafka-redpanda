include "root" {
  path = find_in_parent_folders()
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders())}/_envcommon/karpenter.hcl"
  merge_strategy = "deep"
}

# dev: small cluster-wide vCPU ceiling to cap spend.
inputs = {
  cpu_limit      = 32
  capacity_types = ["spot"] # dev tolerates interruptions
}
