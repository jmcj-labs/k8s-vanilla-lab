terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.46"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  # Multi-account guard: with two accounts in play (management for Identity
  # Center, member for the lab) an apply against the wrong credentials must
  # fail fast. Empty (unset) skips the guard for backwards compatibility.
  allowed_account_ids = var.lab_account_id != "" ? [var.lab_account_id] : null

  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project
      Owner       = var.owner
      ManagedBy   = "opentofu"
      Cluster     = var.cluster_name
    }
  }
}
