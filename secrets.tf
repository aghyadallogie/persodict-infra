locals {
  environments = ["testing", "staging", "prod"]
}

resource "aws_secretsmanager_secret" "app" {
  for_each = toset(local.environments)

  name                    = "persodict/${each.key}"
  description             = "Persodict app secrets for ${each.key} environment"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "app" {
  for_each = toset(local.environments)

  secret_id = aws_secretsmanager_secret.app[each.key].id

  secret_string = jsonencode({
    DATABASE_URL   = "REPLACE_ME"
    DEEPL_AUTH_KEY = "REPLACE_ME"
    JWT_SECRET     = "REPLACE_ME"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}