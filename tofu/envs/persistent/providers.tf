terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # Deliberately LOCAL state (same pattern as the identity stack): this stack
  # has its own lifecycle — applied by a human, never by the Apply/Destroy
  # pipeline. Backups must survive any cluster destroy, so this stack must
  # never share a lifecycle (or a pipeline) with the cluster stack. The state
  # file is gitignored.
  backend "local" {}
}

provider "aws" {
  # Backups live in the LAB account, next to the cluster they protect —
  # unlike the identity stack (management account, us-east-1).
  region              = var.aws_region
  profile             = var.aws_profile != "" ? var.aws_profile : null
  allowed_account_ids = [var.lab_account_id]

  default_tags {
    tags = {
      Project   = "k8s-vanilla-lab"
      Stack     = "persistent"
      ManagedBy = "opentofu-local"
    }
  }
}
