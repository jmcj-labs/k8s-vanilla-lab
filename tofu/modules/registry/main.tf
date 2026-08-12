# Private ECR registry for logistics-lab (Repo 2) + its dedicated CI role.
#
# Separation of duties (ADR-006): the infra CI role MANAGES these resources
# declaratively but holds no runtime push/pull; logistics-lab-ci can push
# images and nothing else; the worker instance role can only pull these four
# repositories. Images are tagged by commit SHA — tags are IMMUTABLE, so no
# `latest` and no tag reuse, ever.

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

resource "aws_ecr_repository" "app" {
  for_each = toset(var.repositories)

  name = each.value

  # IMMUTABLE: a pushed SHA tag can never be repointed — what ran is what
  # the tag says, forever.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # Ephemeral-lab coherence: `tofu destroy` deletes repositories AND any
  # images inside them. Documented in CLUSTER.md.
  force_delete = true

  tags = merge(
    var.tags,
    {
      Name = each.value
      Role = "app-registry"
    }
  )
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images older than 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ── Dedicated OIDC CI role for the app repository ────────────────────────────
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "app_ci" {
  name        = var.ci_role_name
  description = "OIDC CI role for ${var.app_repo}: push/pull on its four ECR repositories, nothing else"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubOIDCAppRepo"
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          # Exactly this repo, exactly main or release tags — never a
          # wildcard that admits other repos or the whole org.
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
              "repo:${var.app_repo}:ref:refs/heads/main",
              "repo:${var.app_repo}:ref:refs/tags/*"
            ]
          }
        }
      }
    ]
  })

  tags = merge(
    var.tags,
    {
      Name = var.ci_role_name
      Role = "app-ci"
    }
  )
}

resource "aws_iam_role_policy" "app_ci_ecr" {
  name = "${var.ci_role_name}-ecr-push"
  role = aws_iam_role.app_ci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuthToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PushPullAppRepositories"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = [for r in aws_ecr_repository.app : r.arn]
      }
    ]
  })
}
