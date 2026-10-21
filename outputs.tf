output "ci_aws_access_key_id" {
  description = "Access key ID for GitHub Actions ECR push"
  value       = aws_iam_access_key.github_actions_ecr.id
}

output "ci_aws_secret_access_key" {
  description = "Secret access key for GitHub Actions ECR push"
  value       = aws_iam_access_key.github_actions_ecr.secret
  sensitive   = true
}