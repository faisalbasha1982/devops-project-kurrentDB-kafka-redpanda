# -----------------------------------------------------------------------------
# Cluster addons + example IRSA roles.
#
# This module wires the reusable irsa module to concrete workloads, so a
# reviewer sees IRSA used end-to-end rather than in the abstract:
#   (a) AWS Load Balancer Controller  -> AWS-managed-style policy
#   (b) Aequor app role (settlement + rebuild) -> scoped S3 read/write to the
#       KurrentDB chunk cold-archive bucket (ties to Phase 2d DR archiving)
#   (c) external-dns (optional)       -> Route53 record management
# -----------------------------------------------------------------------------

# --- (b) DR cold-archive bucket --------------------------------------------
resource "aws_s3_bucket" "kurrentdb_archive" {
  bucket = var.archive_bucket_name
  tags   = merge(var.tags, { "aequor.io/purpose" = "kurrentdb-chunk-archive" })
}

resource "aws_s3_bucket_versioning" "kurrentdb_archive" {
  bucket = aws_s3_bucket.kurrentdb_archive.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "kurrentdb_archive" {
  bucket                  = aws_s3_bucket.kurrentdb_archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kurrentdb_archive" {
  bucket = aws_s3_bucket.kurrentdb_archive.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "kurrentdb_archive" {
  bucket = aws_s3_bucket.kurrentdb_archive.id
  rule {
    id     = "cold-archive-transition"
    status = "Enabled"
    filter {}
    # Chunks are immutable once sealed; age them into cheap storage.
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}

data "aws_iam_policy_document" "app_s3" {
  statement {
    sid       = "ListArchiveBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.kurrentdb_archive.arn]
  }
  statement {
    sid    = "ReadWriteArchiveObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.kurrentdb_archive.arn}/*"]
  }
}

module "app_role" {
  source = "../irsa"

  role_name         = "${var.cluster_name}-aequor-app"
  oidc_provider_arn = var.oidc_provider_arn
  # Both settlement and the one-shot rebuild tool archive/restore chunks.
  namespace_service_accounts = [
    "${var.app_namespace}:aequor-settlement",
    "${var.app_namespace}:aequor-rebuild",
  ]
  inline_policy_json = data.aws_iam_policy_document.app_s3.json
  tags               = var.tags
}

# --- (a) AWS Load Balancer Controller --------------------------------------
# The controller's IAM policy is large + AWS-published; in a real repo you'd
# pull it from the upstream JSON. We attach a focused subset that covers the
# ingress/ELBv2 path Aequor needs (metrics dashboards behind an ALB).
data "aws_iam_policy_document" "lb_controller" {
  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:*",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcs",
      "ec2:DescribeInstances",
      "ec2:DescribeAvailabilityZones",
      "ec2:CreateSecurityGroup",
      "ec2:CreateTags",
      "ec2:AuthorizeSecurityGroupIngress",
      "acm:ListCertificates",
      "acm:DescribeCertificate",
      "wafv2:GetWebACL",
      "shield:GetSubscriptionState",
    ]
    resources = ["*"]
  }
}

module "lb_controller_role" {
  source = "../irsa"

  role_name                  = "${var.cluster_name}-aws-lb-controller"
  oidc_provider_arn          = var.oidc_provider_arn
  namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
  inline_policy_json         = data.aws_iam_policy_document.lb_controller.json
  tags                       = var.tags
}

resource "helm_release" "aws_lb_controller" {
  count = var.install_aws_lb_controller ? 1 : 0

  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_lb_controller_chart_version

  values = [yamlencode({
    clusterName = var.cluster_name
    region      = var.region
    vpcId       = var.vpc_id
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.lb_controller_role.role_arn
      }
    }
  })]
}

# --- (c) external-dns (optional) -------------------------------------------
data "aws_iam_policy_document" "external_dns" {
  count = var.enable_external_dns ? 1 : 0
  statement {
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [var.route53_zone_arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["route53:ListHostedZones", "route53:ListResourceRecordSets"]
    resources = ["*"]
  }
}

module "external_dns_role" {
  source = "../irsa"
  count  = var.enable_external_dns ? 1 : 0

  role_name                  = "${var.cluster_name}-external-dns"
  oidc_provider_arn          = var.oidc_provider_arn
  namespace_service_accounts = ["kube-system:external-dns"]
  inline_policy_json         = data.aws_iam_policy_document.external_dns[0].json
  tags                       = var.tags
}
