# -----------------------------------------------------------------------------
# CI/CD IAM User for GitHub Actions (ECR push only)
# -----------------------------------------------------------------------------

resource "aws_iam_user" "github_actions_ecr" {
  name = "github-actions-ecr-push"
  path = "/ci/"

  tags = {
    Project   = "persodict"
    ManagedBy = "terraform"
    Purpose   = "GitHub Actions ECR push"
  }
}

# Least-privilege policy: only what's needed to push to persodict-api
data "aws_iam_policy_document" "github_actions_ecr" {
  statement {
    sid    = "ECRAuthToken"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"] # GetAuthorizationToken has no resource-level permissions
  }

  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.api.arn]
  }
}

resource "aws_iam_user_policy" "github_actions_ecr" {
  name   = "persodict-ecr-push"
  user   = aws_iam_user.github_actions_ecr.name
  policy = data.aws_iam_policy_document.github_actions_ecr.json
}

# Access keys — secret will be written to state. This is acceptable for a
# learning project; in production, use OIDC instead (no long-lived keys).
resource "aws_iam_access_key" "github_actions_ecr" {
  user = aws_iam_user.github_actions_ecr.name
}