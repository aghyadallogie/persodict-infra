# -----------------------------------------------------------------------------
# IRSA Roles for Cluster Add-ons
# -----------------------------------------------------------------------------

locals {
  oidc_issuer = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# =============================================================================
# 1. AWS Load Balancer Controller
# =============================================================================

# ServiceAccount: kube-system/aws-load-balancer-controller
# Official policy JSON from aws-load-balancer-controller repo.
# We fetch it at plan time and inline it. Pinning to a specific release tag.
data "http" "lbc_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.1/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "lbc" {
  name        = "persodict-aws-load-balancer-controller"
  description = "Permissions for AWS Load Balancer Controller"
  policy      = data.http.lbc_iam_policy.response_body
}

data "aws_iam_policy_document" "lbc_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  name               = "persodict-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

# =============================================================================
# 2. External Secrets Operator
# =============================================================================

# ServiceAccount: external-secrets/external-secrets
# Scoped to only secrets under the "persodict/" prefix.
data "aws_iam_policy_document" "eso_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name               = "persodict-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.eso_assume_role.json
}

data "aws_iam_policy_document" "eso_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = ["arn:aws:secretsmanager:us-east-1:*:secret:persodict/*"]
  }
}

resource "aws_iam_policy" "eso" {
  name        = "persodict-external-secrets"
  description = "Read access to persodict secrets in Secrets Manager"
  policy      = data.aws_iam_policy_document.eso_permissions.json
}

resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso.arn
}