# -----------------------------------------------------------------------------
# Reusable IRSA (IAM Roles for Service Accounts) module.
#
# Builds the OIDC-federated trust policy so a Kubernetes ServiceAccount can
# assume an IAM role with no static keys. The exchanged token is scoped to
# `system:serviceaccount:<ns>:<name>` via the `sub` claim, and we also pin the
# `aud` claim to sts.amazonaws.com — both conditions are load-bearing security
# controls, not decoration.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # Restrict which ServiceAccount(s) may assume this role.
    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values   = [for sa in var.namespace_service_accounts : "system:serviceaccount:${sa}"]
    }

    # Pin the audience — without this the trust is far too broad.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

locals {
  # Turn arn:aws:iam::<acct>:oidc-provider/oidc.eks.<region>.amazonaws.com/id/XXXX
  # into the "oidc.eks.../id/XXXX" host used as the condition key prefix.
  oidc_host = replace(var.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")
}

resource "aws_iam_role" "this" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = 3600
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = toset(var.policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline" {
  count  = var.inline_policy_json == null ? 0 : 1
  name   = "${var.role_name}-inline"
  role   = aws_iam_role.this.id
  policy = var.inline_policy_json
}
