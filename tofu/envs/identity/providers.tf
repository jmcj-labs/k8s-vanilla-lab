terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # Deliberately LOCAL state: this stack lives in the management account with
  # its own lifecycle — applied by a human, never by the Apply/Destroy
  # pipeline, and never sharing state with the lab stack. The state file is
  # gitignored (contains account IDs and personal data).
  backend "local" {}
}

provider "aws" {
  # IAM Identity Center lives in the management account, region us-east-1.
  region              = "us-east-1"
  profile             = var.aws_profile != "" ? var.aws_profile : null
  allowed_account_ids = [var.management_account_id]
}
