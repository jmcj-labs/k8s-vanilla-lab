#!/usr/bin/env bash
# One-time AWS setup for k8s-vanilla-lab.
# Idempotent: existing resources are verified, not recreated.
# Usage: AWS_PROFILE=<profile> make bootstrap-aws
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
GITHUB_ORG="jmcj-labs"
GITHUB_REPO="k8s-vanilla-lab"
IAM_ROLE_NAME="k8s-vanilla-lab-github-actions"
DYNAMODB_TABLE="k8s-vanilla-lab-tflock"
OIDC_URL="https://token.actions.githubusercontent.com"
# GitHub's well-known OIDC thumbprint. AWS validates via JWKS since 2023,
# but create-open-id-connect-provider still requires a syntactically valid value.
GITHUB_OIDC_THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date +'%H:%M:%S')]   $*"; }
ok()   { echo "[$(date +'%H:%M:%S')] ✓ $*"; }
warn() { echo "[$(date +'%H:%M:%S')] ⚠ $*" >&2; }
fail() { echo "[$(date +'%H:%M:%S')] ✗ $*" >&2; exit 1; }

# ── Step 0: Prerequisites ─────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  k8s-vanilla-lab — AWS bootstrap"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log "Step 0/4: Checking prerequisites"
command -v aws >/dev/null || fail "AWS CLI not found. Install: https://aws.amazon.com/cli/"
command -v jq  >/dev/null || fail "jq not found. Install: brew install jq / apt install jq"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="k8s-vanilla-lab-tfstate-${ACCOUNT_ID}"
log "Account : ${ACCOUNT_ID}"
log "Region  : ${AWS_REGION}"
log "Bucket  : ${BUCKET_NAME}"
log "Table   : ${DYNAMODB_TABLE}"
log "Role    : ${IAM_ROLE_NAME}"
ok "Prerequisites satisfied"
echo ""

# ── Step 1: S3 state bucket ───────────────────────────────────────────────────
log "Step 1/4: S3 state bucket (${BUCKET_NAME})"

if aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${AWS_REGION}" 2>/dev/null; then
  VERSIONING=$(aws s3api get-bucket-versioning \
    --bucket "${BUCKET_NAME}" \
    --query Status --output text 2>/dev/null || echo "None")
  if [ "${VERSIONING}" != "Enabled" ]; then
    warn "Versioning not Enabled (${VERSIONING}) — enabling now"
    aws s3api put-bucket-versioning \
      --bucket "${BUCKET_NAME}" \
      --versioning-configuration Status=Enabled
  fi
  ok "Already exists (versioning=${VERSIONING})"
else
  log "Creating bucket..."

  if [ "${AWS_REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${AWS_REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${AWS_REGION}" \
      --create-bucket-configuration LocationConstraint="${AWS_REGION}"
  fi

  aws s3api put-bucket-versioning \
    --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket "${BUCKET_NAME}" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
        "BucketKeyEnabled": true
      }]
    }'

  aws s3api put-public-access-block \
    --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  BUCKET_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyHTTP",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": [
      "arn:aws:s3:::${BUCKET_NAME}",
      "arn:aws:s3:::${BUCKET_NAME}/*"
    ],
    "Condition": {
      "Bool": {"aws:SecureTransport": "false"}
    }
  }]
}
JSON
  )
  aws s3api put-bucket-policy --bucket "${BUCKET_NAME}" --policy "${BUCKET_POLICY}"

  ok "Created (versioning, SSE-S3, public-access-block, HTTPS-only policy)"
fi
echo ""

# ── Step 2: DynamoDB lock table ───────────────────────────────────────────────
log "Step 2/4: DynamoDB lock table (${DYNAMODB_TABLE})"

TABLE_STATUS=$(aws dynamodb describe-table \
  --table-name "${DYNAMODB_TABLE}" \
  --region "${AWS_REGION}" \
  --query Table.TableStatus \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [ "${TABLE_STATUS}" = "ACTIVE" ]; then
  ok "Already exists and ACTIVE"
else
  log "Creating table..."
  aws dynamodb create-table \
    --table-name "${DYNAMODB_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${AWS_REGION}"
  log "Waiting for table to become ACTIVE..."
  aws dynamodb wait table-exists \
    --table-name "${DYNAMODB_TABLE}" \
    --region "${AWS_REGION}"
  ok "Created"
fi
echo ""

# ── Step 3: OIDC provider ─────────────────────────────────────────────────────
log "Step 3/4: OIDC provider (token.actions.githubusercontent.com)"

OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "${OIDC_ARN}" >/dev/null 2>&1; then
  ok "Already exists (${OIDC_ARN})"
else
  log "Creating OIDC provider..."
  CREATE_OUT=$(aws iam create-open-id-connect-provider \
    --url "${OIDC_URL}" \
    --thumbprint-list "${GITHUB_OIDC_THUMBPRINT}" \
    --client-id-list sts.amazonaws.com \
    --query OpenIDConnectProviderArn \
    --output text 2>&1) && {
    OIDC_ARN="${CREATE_OUT}"
    ok "Created (${OIDC_ARN})"
  } || {
    if echo "${CREATE_OUT}" | grep -q "EntityAlreadyExists"; then
      warn "OIDC provider already exists but could not be read with current permissions; continuing"
      ok "Already exists (${OIDC_ARN})"
    else
      echo "${CREATE_OUT}" >&2
      exit 1
    fi
  }
fi
echo ""

# ── Step 4: IAM role ──────────────────────────────────────────────────────────
log "Step 4/4: IAM role (${IAM_ROLE_NAME})"

TRUST_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
      }
    }
  }]
}
JSON
)

PERMISSIONS_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2AndNetworking",
      "Effect": "Allow",
      "Action": [
        "ec2:AllocateAddress",
        "ec2:AssociateAddress",
        "ec2:AssociateRouteTable",
        "ec2:AttachInternetGateway",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CreateInternetGateway",
        "ec2:CreateRoute",
        "ec2:CreateRouteTable",
        "ec2:CreateSecurityGroup",
        "ec2:CreateSubnet",
        "ec2:CreateTags",
        "ec2:CreateVpc",
        "ec2:DeleteInternetGateway",
        "ec2:DeleteNetworkInterface",
        "ec2:DeleteRoute",
        "ec2:DeleteRouteTable",
        "ec2:DeleteSecurityGroup",
        "ec2:DeleteSubnet",
        "ec2:DeleteTags",
        "ec2:DeleteVpc",
        "ec2:Describe*",
        "ec2:DetachInternetGateway",
        "ec2:DisassociateAddress",
        "ec2:DisassociateRouteTable",
        "ec2:ModifyInstanceAttribute",
        "ec2:ModifySubnetAttribute",
        "ec2:ModifyVpcAttribute",
        "ec2:ReleaseAddress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:CancelSpotInstanceRequests",
        "ec2:RequestSpotInstances",
        "ec2:RunInstances",
        "ec2:StopInstances",
        "ec2:TerminateInstances"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMForNodeRoles",
      "Effect": "Allow",
      "Action": [
        "iam:AddRoleToInstanceProfile",
        "iam:AttachRolePolicy",
        "iam:CreateInstanceProfile",
        "iam:CreateRole",
        "iam:DeleteInstanceProfile",
        "iam:DeleteRole",
        "iam:DeleteRolePolicy",
        "iam:DetachRolePolicy",
        "iam:GetInstanceProfile",
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:ListRolePolicies",
        "iam:PassRole",
        "iam:PutRolePolicy",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:TagInstanceProfile",
        "iam:TagRole",
        "iam:UntagRole"
      ],
      "Resource": [
        "arn:aws:iam::${ACCOUNT_ID}:role/k8s-vanilla-lab-*",
        "arn:aws:iam::${ACCOUNT_ID}:instance-profile/k8s-vanilla-lab-*"
      ]
    },
    {
      "Sid": "SSMParameters",
      "Effect": "Allow",
      "Action": [
        "ssm:DeleteParameter",
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath",
        "ssm:PutParameter"
      ],
      "Resource": "arn:aws:ssm:*:${ACCOUNT_ID}:parameter/k8s/*"
    },
    {
      "Sid": "TofuStateS3",
      "Effect": "Allow",
      "Action": [
        "s3:DeleteObject",
        "s3:GetBucketAcl",
        "s3:GetBucketVersioning",
        "s3:GetEncryptionConfiguration",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::k8s-vanilla-lab-tfstate-*",
        "arn:aws:s3:::k8s-vanilla-lab-tfstate-*/*"
      ]
    },
    {
      "Sid": "TofuStateDynamoDB",
      "Effect": "Allow",
      "Action": [
        "dynamodb:DeleteItem",
        "dynamodb:DescribeTable",
        "dynamodb:GetItem",
        "dynamodb:PutItem"
      ],
      "Resource": "arn:aws:dynamodb:*:${ACCOUNT_ID}:table/k8s-vanilla-lab-tflock"
    },
    {
      "Sid": "KMSForSSMSecureString",
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SpotServiceLinkedRole",
      "Effect": "Allow",
      "Action": "iam:CreateServiceLinkedRole",
      "Resource": "arn:aws:iam::*:role/aws-service-role/spot.amazonaws.com/*",
      "Condition": {
        "StringLike": {
          "iam:AWSServiceName": "spot.amazonaws.com"
        }
      }
    }
  ]
}
JSON
)

if aws iam get-role --role-name "${IAM_ROLE_NAME}" >/dev/null 2>&1; then
  log "Role exists — refreshing trust and permissions policies"
  aws iam update-assume-role-policy \
    --role-name "${IAM_ROLE_NAME}" \
    --policy-document "${TRUST_POLICY}"
  aws iam put-role-policy \
    --role-name "${IAM_ROLE_NAME}" \
    --policy-name "${IAM_ROLE_NAME}-policy" \
    --policy-document "${PERMISSIONS_POLICY}"
  ok "Updated"
else
  log "Creating role..."
  aws iam create-role \
    --role-name "${IAM_ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --description "GitHub Actions OIDC role for k8s-vanilla-lab CI" \
    --output text >/dev/null
  aws iam put-role-policy \
    --role-name "${IAM_ROLE_NAME}" \
    --policy-name "${IAM_ROLE_NAME}-policy" \
    --policy-document "${PERMISSIONS_POLICY}"
  ok "Created"
fi

ROLE_ARN=$(aws iam get-role \
  --role-name "${IAM_ROLE_NAME}" \
  --query Role.Arn \
  --output text)

# ── Output ────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Bootstrap complete"
echo ""
echo "  Role ARN: ${ROLE_ARN}"
echo ""
echo "Set this as a GitHub Actions Variable at:"
echo "  https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/settings/variables/actions"
echo "  Name:  AWS_ROLE_ARN"
echo "  Value: ${ROLE_ARN}"
echo ""
echo "Also ensure these Variables are configured:"
echo "  AWS_REGION          = ${AWS_REGION}"
echo "  TF_VAR_MY_IP        = <your-laptop-ip>/32"
echo "  TF_VAR_SSH_KEY_NAME = <your-ec2-key-pair-name>"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
