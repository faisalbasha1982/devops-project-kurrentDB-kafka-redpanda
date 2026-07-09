# -----------------------------------------------------------------------------
# Karpenter — app-tier autoscaling for Aequor.
#
# The managed node group (eks module) only carries system add-ons. Everything
# else — feed/capture/settlement/reconciler/projection/telemetry pods and the
# KurrentDB/TigerBeetle StatefulSets — schedules onto Karpenter-provisioned
# nodes: spot-first with on-demand fallback, consolidation on for bin-packing.
#
# Two parts:
#   1. IAM/IRSA + the controller (the upstream eks module's karpenter submodule).
#   2. Karpenter Helm release + the v1 NodePool / EC2NodeClass CRs.
# -----------------------------------------------------------------------------

data "aws_ecrpublic_authorization_token" "token" {
  # Karpenter's chart + controller image live in ECR Public; needs an auth token.
  provider = aws.us_east_1
}

# IRSA role + instance profile + interruption SQS queue for the controller.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.24"

  cluster_name = var.cluster_name

  # v1 (Karpenter >=1.0) IAM permission set. Auth is EKS Pod Identity — the
  # submodule creates the controller role + a pod-identity association for the
  # kube-system/karpenter ServiceAccount, so no IRSA annotation is needed on the
  # SA. (OIDC/IRSA still powers the *app* roles in modules/addons.)
  enable_v1_permissions           = true
  namespace                       = "kube-system"
  create_pod_identity_association = true

  # Let Karpenter nodes pull the standard AmazonEKS managed policies.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.tags
}

resource "helm_release" "karpenter" {
  name      = "karpenter"
  namespace = "kube-system"

  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = var.karpenter_chart_version

  # Chart CRDs install NodePool/EC2NodeClass before we apply the CRs below.
  wait = true

  values = [yamlencode({
    settings = {
      clusterName       = var.cluster_name
      clusterEndpoint   = var.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
    # Auth is via Pod Identity (association created by the karpenter submodule),
    # so the SA carries no role-arn annotation.
    serviceAccount = {
      name = "karpenter"
    }
    controller = {
      resources = {
        requests = { cpu = "1", memory = "1Gi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
    }
  })]
}

# --- v1 API CRs -------------------------------------------------------------
# Templated so a reviewer can read the exact YAML that lands in-cluster.
resource "kubectl_manifest" "ec2nodeclass" {
  yaml_body = templatefile("${path.module}/templates/ec2nodeclass.yaml.tftpl", {
    cluster_name   = var.cluster_name
    node_role_name = module.karpenter.node_iam_role_name
  })
  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "nodepool" {
  yaml_body = templatefile("${path.module}/templates/nodepool.yaml.tftpl", {
    instance_categories = jsonencode(var.instance_categories)
    capacity_types      = jsonencode(var.capacity_types)
    cpu_limit           = var.cpu_limit
  })
  depends_on = [kubectl_manifest.ec2nodeclass]
}
