# AWS Bootstrap Guide

One-time setup of the AWS resources that the CI/CD workflows and OpenTofu state backend depend on. Run this once per AWS account before the first `tofu apply`. After completing this guide, proceed to [docs/walkthrough.md](walkthrough.md) for first deployment.

---

## Authentication pattern: local vs CI

The provider is configured with `profile = var.aws_profile`. When the variable is empty (the default), the provider falls through to the standard AWS credential chain — environment variables set by `aws-actions/configure-aws-credentials` in CI. When it has a value, the provider uses that named profile.

| Context | How credentials are resolved |
|---------|------------------------------|
| Local | `aws_profile = "k8s-vanilla-lab"` in `terraform.tfvars`, or `AWS_PROFILE` via `.envrc` + direnv |
| CI (GitHub Actions) | `aws-actions/configure-aws-credentials` sets `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` via OIDC; `aws_profile` is left at its default `""` |

For local setup, copy the provided examples:

```bash
# Option A: direnv (recommended — auto-activates when you cd into the repo)
cp .envrc.example .envrc
direnv allow

# Option B: terraform.tfvars
cp tofu/envs/lab/terraform.tfvars.example tofu/envs/lab/terraform.tfvars
# edit: set aws_profile, my_ip, ssh_key_name
```

---

## 1. Overview

`make bootstrap-aws` runs `scripts/bootstrap-aws.sh`, which creates or verifies:

| Resource | Name |
|----------|------|
| S3 bucket (state) | `k8s-vanilla-lab-tfstate-<ACCOUNT_ID>` |
| DynamoDB table (state lock) | `k8s-vanilla-lab-tflock` |
| IAM OIDC provider | `token.actions.githubusercontent.com` |
| IAM role (CI) | `k8s-vanilla-lab-github-actions` |

The script is **idempotent** — if a resource already exists it verifies the configuration and reports `✓ Already exists`. It is safe to re-run.

It uses the AWS CLI directly (not OpenTofu) to avoid a chicken-and-egg problem: the state backend must exist before `tofu init` can run.

---

## 2. Prerequisites

### AWS account and credentials

You need an IAM user or role with enough permissions to create S3 buckets, DynamoDB tables, IAM OIDC providers, and IAM roles. Admin access works; a scoped policy is out of scope for this guide.

Configure credentials in any of the standard AWS CLI ways:

```bash
# AWS SSO (recommended)
aws sso login --profile k8s-vanilla-lab
export AWS_PROFILE=k8s-vanilla-lab

# Static credentials (not recommended for production)
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=eu-west-1
```

### Tools required

| Tool | Version | Install |
|------|---------|---------|
| AWS CLI | v2 | https://aws.amazon.com/cli/ |
| jq | any | `brew install jq` / `apt install jq` |

---

## 3. Running bootstrap-aws

```bash
# With AWS SSO profile
AWS_PROFILE=k8s-vanilla-lab make bootstrap-aws

# Override region if needed
AWS_PROFILE=k8s-vanilla-lab make bootstrap-aws AWS_REGION=us-east-1
```

---

## 4. Resources created / verified

### 4.1 S3 state bucket

Name: `k8s-vanilla-lab-tfstate-<ACCOUNT_ID>` (account-scoped to avoid global name conflicts)

Configuration applied:
- Versioning enabled (allows state recovery)
- Server-side encryption with SSE-S3 (AES256)
- Public access fully blocked
- Bucket policy denying all HTTP requests (HTTPS only)

If the bucket already exists, the script verifies versioning is `Enabled` and enables it if not. Other settings are not re-applied on existing buckets to avoid conflicts with manual changes.

### 4.2 DynamoDB lock table

Name: `k8s-vanilla-lab-tflock`

Configuration: `LockID` (String) partition key, PAY_PER_REQUEST billing. OpenTofu writes a lock record at the start of each `plan`/`apply`/`destroy` and deletes it on completion.

### 4.3 OIDC provider

URL: `https://token.actions.githubusercontent.com`  
Client ID: `sts.amazonaws.com`

Checked with `aws iam list-open-id-connect-providers` before creating. AWS has validated GitHub tokens via JWKS since 2023, so the thumbprint value is a formality — the well-known value `6938fd4d98bab03faadb97b34396831e3780aea1` is used.

### 4.4 IAM role

Name: `k8s-vanilla-lab-github-actions`

**Trust policy**: allows `sts:AssumeRoleWithWebIdentity` from the OIDC provider, scoped to `repo:jmcj-labs/k8s-vanilla-lab:*`. GitHub does not expose OIDC tokens to fork pull requests by default, so the `:*` subject is safe for this repo.

> **TODO (Fase 6)**: Split into two roles — read-only for PR `validate` workflows (`ref:refs/pull/*`) and full-access for `apply`/`destroy` on `refs/heads/main` only. This further limits blast radius from compromised PRs.

**Permissions policy** (inline, `k8s-vanilla-lab-github-actions-policy`):

| Statement | Actions | Resource scope |
|-----------|---------|----------------|
| `EC2AndNetworking` | Full EC2 CRUD for VPC, subnets, IGW, security groups, EIP, instances | `*` (required by EC2 API) |
| `IAMForNodeRoles` | Create/delete/pass IAM roles and instance profiles for node bootstrapping | `arn:aws:iam::ACCOUNT:role/k8s-vanilla-lab-*` |
| `SSMParameters` | Get/Put/Delete SSM parameters | `arn:aws:ssm:*:ACCOUNT:parameter/k8s/*` |
| `TofuStateS3` | Read/write state file | `arn:aws:s3:::k8s-vanilla-lab-tfstate-*` |
| `TofuStateDynamoDB` | Acquire/release state lock | `arn:aws:dynamodb:*:ACCOUNT:table/k8s-vanilla-lab-tflock` |
| `KMSForSSMSecureString` | Decrypt/encrypt SSM SecureString parameters | `*` ⚠ |
| `SpotServiceLinkedRole` | Create Spot SLR if absent | `arn:aws:iam::*:role/aws-service-role/spot.amazonaws.com/*` |

> **TODO (post-Fase 6)**: Narrow `KMSForSSMSecureString` `Resource` from `*` to the exact key ARN for the `aws/ssm` alias in your account:
> ```bash
> aws kms describe-key --key-id alias/aws/ssm --query KeyMetadata.Arn --output text
> ```
> Then replace `"Resource": "*"` with that ARN in the script and re-run `make bootstrap-aws` to refresh the policy.

---

## 5. Expected output

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  k8s-vanilla-lab — AWS bootstrap
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[10:32:01]   Step 0/4: Checking prerequisites
[10:32:01]   Account : 487985088962
[10:32:01]   Region  : eu-west-1
[10:32:01]   Bucket  : k8s-vanilla-lab-tfstate-487985088962
[10:32:01]   Table   : k8s-vanilla-lab-tflock
[10:32:01]   Role    : k8s-vanilla-lab-github-actions
[10:32:01] ✓ Prerequisites satisfied

[10:32:01]   Step 1/4: S3 state bucket (k8s-vanilla-lab-tfstate-487985088962)
[10:32:02] ✓ Already exists (versioning=Enabled)

[10:32:02]   Step 2/4: DynamoDB lock table (k8s-vanilla-lab-tflock)
[10:32:02] ✓ Already exists and ACTIVE

[10:32:02]   Step 3/4: OIDC provider (token.actions.githubusercontent.com)
[10:32:03] ✓ Already exists (arn:aws:iam::487985088962:oidc-provider/token.actions.githubusercontent.com)

[10:32:03]   Step 4/4: IAM role (k8s-vanilla-lab-github-actions)
[10:32:03]   Role exists — refreshing trust and permissions policies
[10:32:04] ✓ Updated

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ Bootstrap complete

  Role ARN: arn:aws:iam::487985088962:role/k8s-vanilla-lab-github-actions

Set this as a GitHub Actions Variable at:
  https://github.com/jmcj-labs/k8s-vanilla-lab/settings/variables/actions
  Name:  AWS_ROLE_ARN
  Value: arn:aws:iam::487985088962:role/k8s-vanilla-lab-github-actions

Also ensure these Variables are configured:
  AWS_REGION          = eu-west-1
  TF_VAR_MY_IP        = <your-laptop-ip>/32
  TF_VAR_SSH_KEY_NAME = <your-ec2-key-pair-name>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 6. Post-bootstrap: configure GitHub Actions

### 6.1 Set AWS_ROLE_ARN

In your GitHub repository, go to **Settings → Secrets and variables → Actions → Variables** and add:

| Name | Value |
|------|-------|
| `AWS_ROLE_ARN` | The role ARN from the bootstrap output |

A role ARN is not a credential — it is a resource identifier. Storing it as a Variable (not a Secret) is intentional and is the convention used by `aws-actions/configure-aws-credentials` documentation.

### 6.2 Set remaining Variables

All three workflows (validate, apply, destroy) read the following **Variables** from
**Settings → Secrets and variables → Actions → Variables**:

| Variable | Example value | Required by | Notes |
|----------|---------------|-------------|-------|
| `AWS_REGION` | `eu-west-1` | all | Must match the region used for bootstrap |
| `TF_BACKEND_BUCKET` | `k8s-vanilla-lab-tfstate-487985088962` | all | S3 bucket name from bootstrap output |
| `TF_VAR_MY_IP` | `203.0.113.42/32` | validate, apply, destroy | Your public IP for SSH and K8s API security group rules |
| `TF_VAR_SSH_KEY_NAME` | `k8s-vanilla-lab` | validate, apply, destroy | Name of the EC2 key pair in your account |
| `CLUSTER_NAME` | `k8s-vanilla-lab` | apply (smoke-test) | Cluster name; defaults to `k8s-vanilla-lab` if unset |

**Secrets** (Settings → Secrets and variables → Actions → **Secrets**):

| Secret | Notes |
|--------|-------|
| `SLACK_WEBHOOK_URL` | Optional. Incoming webhook URL for apply/destroy notifications. Skip if not using Slack. |

---

## 7. Verifying the setup

```bash
# IAM role exists and trust policy is correct
aws iam get-role --role-name k8s-vanilla-lab-github-actions \
  --query 'Role.{Arn:Arn,Created:CreateDate}' --output table

# Inline policy is attached
aws iam get-role-policy \
  --role-name k8s-vanilla-lab-github-actions \
  --policy-name k8s-vanilla-lab-github-actions-policy \
  --query PolicyDocument --output json | jq '.Statement[].Sid'

# S3 bucket exists and versioning is enabled
aws s3api get-bucket-versioning \
  --bucket "k8s-vanilla-lab-tfstate-$(aws sts get-caller-identity --query Account --output text)"

# DynamoDB table is ACTIVE
aws dynamodb describe-table \
  --table-name k8s-vanilla-lab-tflock \
  --query 'Table.{Status:TableStatus,BillingMode:BillingModeSummary.BillingMode}' \
  --output table

# OIDC provider is registered
aws iam list-open-id-connect-providers \
  --query "OIDCProviderList[?ends_with(Arn, 'token.actions.githubusercontent.com')]"
```

---

## 8. Teardown

> **Warning**: Deleting the S3 bucket destroys the OpenTofu state. If infrastructure is deployed, run `tofu destroy` first or you will lose track of AWS resources and have to clean them up manually.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Delete IAM role (detach inline policy first)
aws iam delete-role-policy \
  --role-name k8s-vanilla-lab-github-actions \
  --policy-name k8s-vanilla-lab-github-actions-policy
aws iam delete-role --role-name k8s-vanilla-lab-github-actions

# Delete OIDC provider
OIDC_ARN=$(aws iam list-open-id-connect-providers \
  --query "OIDCProviderList[?ends_with(Arn, 'token.actions.githubusercontent.com')].Arn" \
  --output text)
[ -n "${OIDC_ARN}" ] && aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_ARN}"

# Delete DynamoDB table
aws dynamodb delete-table --table-name k8s-vanilla-lab-tflock

# Empty and delete S3 bucket (⚠ destroys all state versions)
aws s3 rm "s3://k8s-vanilla-lab-tfstate-${ACCOUNT_ID}" --recursive
aws s3api delete-bucket --bucket "k8s-vanilla-lab-tfstate-${ACCOUNT_ID}"
```
