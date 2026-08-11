# Identity Center stack — management account, us-east-1.
#
# Separate lifecycle on purpose: persistent, applied locally with
# management-account credentials, NEVER part of apply.yml/destroy.yml.
# It provisions WHO can bridge into the lab account; the lab stack
# provisions the stable roles they bridge to (tofu/modules/access).

data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

  platform_admin_role_arn = "arn:aws:iam::${var.lab_account_id}:role/${var.cluster_name}-platform-admin"
  developer_role_arn      = "arn:aws:iam::${var.lab_account_id}:role/${var.cluster_name}-developer"
}

# ── Existing human user: looked up, NEVER managed ────────────────────────────
data "aws_identitystore_user" "platform" {
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = var.platform_user_name
    }
  }
}

# ── New developer identity (this one IS managed here) ────────────────────────
resource "aws_identitystore_user" "jm_dev" {
  identity_store_id = local.identity_store_id

  user_name    = var.dev_user_name
  display_name = "${var.dev_given_name} ${var.dev_family_name} (dev)"

  name {
    given_name  = var.dev_given_name
    family_name = var.dev_family_name
  }

  emails {
    value   = var.dev_email
    primary = true
  }
}

# ── Groups ───────────────────────────────────────────────────────────────────
resource "aws_identitystore_group" "platform_admins" {
  identity_store_id = local.identity_store_id
  display_name      = "platform-admins"
  description       = "Humans who bridge to ${var.cluster_name}-platform-admin (cluster-admin)"
}

resource "aws_identitystore_group" "developers" {
  identity_store_id = local.identity_store_id
  display_name      = "developers"
  description       = "Humans who bridge to ${var.cluster_name}-developer (namespace logistics)"
}

resource "aws_identitystore_group_membership" "platform_user" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.platform_admins.group_id
  member_id         = data.aws_identitystore_user.platform.user_id
}

resource "aws_identitystore_group_membership" "jm_dev" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.developers.group_id
  member_id         = aws_identitystore_user.jm_dev.user_id
}

# ── Permission sets: ONLY sts:AssumeRole on the matching stable role ─────────
# No other AWS permissions: jm-dev can open the portal/console but every
# EC2/IAM query returns AccessDenied. The bridge is the whole point.
resource "aws_ssoadmin_permission_set" "platform_bridge" {
  name             = "K8sPlatformBridge"
  description      = "Bridge to ${var.cluster_name}-platform-admin — sts:AssumeRole only"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT8H"
}

resource "aws_ssoadmin_permission_set_inline_policy" "platform_bridge" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.platform_bridge.arn

  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AssumePlatformAdmin"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = local.platform_admin_role_arn
    }]
  })
}

resource "aws_ssoadmin_permission_set" "dev_bridge" {
  name             = "K8sDevBridge"
  description      = "Bridge to ${var.cluster_name}-developer — sts:AssumeRole only"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT8H"
}

resource "aws_ssoadmin_permission_set_inline_policy" "dev_bridge" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.dev_bridge.arn

  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AssumeDeveloper"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = local.developer_role_arn
    }]
  })
}

# ── Account assignments: to the MEMBER account, not the management one ───────
# This is what makes Identity Center provision the AWSReservedSSO_* roles in
# the lab account — the ARNs the stable roles' trust policies match on.
resource "aws_ssoadmin_account_assignment" "platform" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.platform_bridge.arn
  principal_id       = aws_identitystore_group.platform_admins.group_id
  principal_type     = "GROUP"
  target_id          = var.lab_account_id
  target_type        = "AWS_ACCOUNT"
}

resource "aws_ssoadmin_account_assignment" "developers" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.dev_bridge.arn
  principal_id       = aws_identitystore_group.developers.group_id
  principal_type     = "GROUP"
  target_id          = var.lab_account_id
  target_type        = "AWS_ACCOUNT"
}
