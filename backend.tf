terraform {
  backend "s3" {
    bucket         = "zenlogie-terraform-state-persodict"
    key            = "infra/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}