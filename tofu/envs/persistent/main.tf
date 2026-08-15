# Persistent backups stack — lab account, own lifecycle.
#
# Second deliberately-persistent piece of the lab (after the identity stack):
# ONE bucket for all cluster backups, prefixes etcd/ and cnpg/. Applied and
# destroyed manually — NEVER referenced by apply.yml/destroy.yml. The whole
# point is that `tofu destroy` of the cluster can be total (PVC volumes
# included) without losing anything: S3 is the conservation path.
#
# PLAN-SPRINTS S2 piece 1: "sin restore probado no es backup".

data "aws_caller_identity" "current" {}

locals {
  bucket_name = var.bucket_name != "" ? var.bucket_name : "${var.cluster_name}-backups-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "backups" {
  bucket = local.bucket_name

  tags = {
    Name = local.bucket_name
    Role = "backups"
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Accepted trade-off (2026-08-15, ratified in the #S2-1 cross-review): SSE-S3
# instead of a customer managed key. A CMK WOULD add revocation and key-usage
# auditability; what it does NOT change in this lab is the blast radius of an
# account compromise (key and data live in the same lab account). Cost and
# key-policy complexity are not worth that delta until backups carry data
# with compliance requirements. Scoped to THIS resource, expires at the
# start of Sprint 3 so the decision is re-examined, not inherited.
#trivy:ignore:AVD-AWS-0132:exp:2026-09-01
resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-etcd"
    status = "Enabled"

    filter {
      prefix = "etcd/"
    }

    expiration {
      days = var.etcd_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.etcd_retention_days
    }
  }

  rule {
    id     = "expire-cnpg"
    status = "Enabled"

    filter {
      prefix = "cnpg/"
    }

    expiration {
      days = var.cnpg_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.cnpg_retention_days
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ── IAM user for CNPG/barman ─────────────────────────────────────────────────
# Why a static IAM user and not the instance profile: the clusterwide IMDS
# deny (platform/policies/ccnp-deny-imds.yaml) blocks the CNPG pods from the
# instance metadata service, and that policy is ratified as untouchable — we
# prefer one minimal, explicit, prefix-scoped static credential over widening
# the IMDS exception. Its lifecycle is the bucket's, not the cluster's.
#
# The ACCESS KEYS are deliberately NOT managed here (they would land in the
# state file). The operator creates them once, manually, and deposits them in
# SSM — see README.md.
resource "aws_iam_user" "cnpg_backup" {
  name = "${var.cluster_name}-cnpg-backup"

  tags = {
    Name = "${var.cluster_name}-cnpg-backup"
    Role = "cnpg-backup"
  }
}

resource "aws_iam_user_policy" "cnpg_backup" {
  name = "${var.cluster_name}-cnpg-backup-s3"
  user = aws_iam_user.cnpg_backup.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CnpgPrefixObjects"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.backups.arn}/cnpg/*"
      },
      {
        # No prefix condition ON PURPOSE (INCIDENTS #14): barman-cloud runs
        # HeadBucket as its connectivity check, and HeadBucket maps to
        # s3:ListBucket with NO prefix in the request — a prefix condition
        # 403s the check and archiving never starts. Cost of the widening:
        # this user can list KEY NAMES bucket-wide (etcd/ included); object
        # CONTENT stays scoped to cnpg/* above.
        Sid      = "CnpgBucketList"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.backups.arn
      }
    ]
  })
}
