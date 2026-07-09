include "root" {
  path = find_in_parent_folders()
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders())}/_envcommon/addons.hcl"
  merge_strategy = "deep"
}

inputs = {
  install_aws_lb_controller = true
  enable_external_dns       = false
}
