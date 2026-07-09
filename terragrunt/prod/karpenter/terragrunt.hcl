include "root" {
  path = find_in_parent_folders()
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders())}/_envcommon/karpenter.hcl"
  merge_strategy = "deep"
}

# prod: higher ceiling, spot-first but on-demand fallback for stateful workloads.
inputs = {
  cpu_limit      = 200
  capacity_types = ["spot", "on-demand"]
}
