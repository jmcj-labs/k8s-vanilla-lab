# Stable Kubernetes-access IAM roles (member/lab account).
#
# ZERO AWS permissions of their own: their only function is to be the stable
# identity that STS vends and aws-iam-authenticator maps to a Kubernetes
# group. Humans reach them through the Identity Center bridge permission
# sets (tofu/envs/identity); CI reaches them directly for the RBAC smoke.
#
# Trust pattern (AWS-documented for permission-set principals): trust the
# account root + restrict with an ArnLike condition on aws:PrincipalArn
# matching the AWSReservedSSO_* role that Identity Center provisions in THIS
# account. Identity Center lives in us-east-1, so the role path carries no
# region segment; the wildcard covers only the changing suffix.

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  ci_role    = "arn:aws:iam::${local.account_id}:role/${var.github_actions_role_name}"
}

locals {
  roles = {
    platform-admin = {
      permission_set = "K8sPlatformBridge"
      description    = "Stable identity for cluster-admin access via aws-iam-authenticator"
    }
    developer = {
      permission_set = "K8sDevBridge"
      description    = "Stable identity for namespace-scoped (logistics) access via aws-iam-authenticator"
    }
  }
}

resource "aws_iam_role" "access" {
  for_each = local.roles

  name        = "${var.cluster_name}-${each.key}"
  description = each.value.description

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "IdentityCenterBridge"
          Effect = "Allow"
          Principal = {
            AWS = "arn:aws:iam::${local.account_id}:root"
          }
          Action = "sts:AssumeRole"
          Condition = {
            ArnLike = {
              "aws:PrincipalArn" = "arn:aws:iam::${local.account_id}:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_${each.value.permission_set}_*"
            }
          }
        },
        {
          Sid    = "CISmokeTest"
          Effect = "Allow"
          Principal = {
            AWS = local.ci_role
          }
          Action = "sts:AssumeRole"
        }
      ],
      # The app repo's CI role (logistics-lab-ci) assumes ONLY the developer
      # role — its deploy pipeline authenticates to the cluster as developer.
      # Fresh-safe pattern (same as the Identity Center bridge): trust the
      # account root and restrict with ArnEquals on aws:PrincipalArn. A bare
      # role ARN in Principal becomes an unresolvable principal if the role is
      # ever recreated, breaking the trust; root + condition never does.
      # Constructed as a string (not a module ref) to avoid an access<->registry
      # cycle; the registry module grants the reciprocal sts:AssumeRole.
      each.key == "developer" ? [
        {
          Sid    = "AppCIAssumesDeveloper"
          Effect = "Allow"
          Principal = {
            AWS = "arn:aws:iam::${local.account_id}:root"
          }
          Action = "sts:AssumeRole"
          Condition = {
            ArnEquals = {
              "aws:PrincipalArn" = "arn:aws:iam::${local.account_id}:role/${var.app_ci_role_name}"
            }
          }
        }
      ] : []
    )
  })

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-${each.key}"
      Role = "k8s-access"
    }
  )
}
