# Identity stack — IAM Identity Center (management account)

Separate-lifecycle stack: **persistent**, applied **locally** with
management-account credentials, region **us-east-1**. It is never part of
`apply.yml`/`destroy.yml` — destroying the cluster must never touch
identities.

What it manages:

| Piece | Managed? |
|---|---|
| Existing human user (`platform_user_name`) | **No** — data-source lookup; only its `platform-admins` membership is managed. Its current `AdministratorAccess` is out of scope here |
| `jm-dev` user | Yes (created) |
| Groups `platform-admins` / `developers` | Yes |
| Permission sets `K8sPlatformBridge` / `K8sDevBridge` | Yes — inline policy with **only** `sts:AssumeRole` on the matching stable role |
| Account assignments | Yes — each group + permission set assigned to the **lab member account** (that is where Identity Center provisions the `AWSReservedSSO_*` roles) |

## Apply

```bash
cd tofu/envs/identity
cp terraform.tfvars.example terraform.tfvars   # fill in — never commit
tofu init
tofu plan
tofu apply
```

State is **local** (gitignored): it contains account IDs and personal data,
and this stack must not share the lab's S3 state or credentials.

## Onboarding of jm-dev (manual, once)

`aws_identitystore_user` does **not** send an activation email. After apply:
Identity Center console (management account, us-east-1) → Users → `jm-dev` →
**Reset password** → choose "generate a one-time password" and hand it over
out-of-band. MFA enrolment happens at first login.

## Notes

- Identity Center lives in us-east-1: the provisioned `AWSReservedSSO_*`
  role ARNs carry **no region segment** in their path (AWS-documented
  special case) — the trust policies in `tofu/modules/access` rely on this.
- If the org uses SCPs on the lab account, verify they do not block
  `sts:AssumeRole` on `k8s-vanilla-lab-*` roles nor the IAM operations the
  CI role needs to manage them (full Tofu lifecycle).
