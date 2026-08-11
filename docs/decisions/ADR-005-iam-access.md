# ADR-005: IAM-based Kubernetes access via aws-iam-authenticator

**Status**: Accepted
**Date**: 2026-08-11

## Context

Daily access to the cluster was the kubeadm admin kubeconfig fetched from SSM
(ADR-004): a static X.509 certificate, valid one year, one shared
cluster-admin identity, revocable only by destroying the cluster. Acceptable
as a bootstrap/CI mechanism; unacceptable as the everyday human path once
there is more than one identity or any notion of least privilege. The org
runs IAM Identity Center in the **management account** (us-east-1) while the
cluster and all lab IAM live in a **member account**.

## Decision

Authenticate humans and CI against the API server with **aws-iam-authenticator
v0.7.18** (token webhook), mapping stable IAM roles to Kubernetes groups.
The admin kubeconfig stays in SSM strictly as **break-glass** (ADR-004
intact, verified by the smoke test).

Identity flow: Identity Center group → bridge permission set
(`sts:AssumeRole` only) → stable role in the lab account → authenticator →
Kubernetes group → RBAC.

### Decision 1 — IAM tokens vs OIDC/Dex vs CSR-signed certs

- **CSR-signed per-user certs**: no revocation story (same flaw as the admin
  kubeconfig, multiplied by users).
- **OIDC (Dex/Entra)**: the right long-term shape, but demands an IdP the
  lab does not have and a second identity store next to AWS.
- **IAM (chosen)**: identities, MFA, sessions and offboarding already live
  in Identity Center; STS gives short-lived credentials for free; CI (OIDC
  → IAM) uses the same door. Revocation = removing a group membership.

### Decision 2 — Bridge permission sets vs trusting Identity Center groups

IAM trust policies cannot reference Identity Center groups — a "group trust"
is unimplementable. The AWS-documented pattern is trusting the
`AWSReservedSSO_<PermissionSet>_*` role that Identity Center provisions in
the member account, via `ArnLike` on `aws:PrincipalArn` (no region segment
in the path: Identity Center lives in us-east-1). The permission sets carry
**only** `sts:AssumeRole` on their stable role, so the bridge grants nothing
else in AWS — `jm-dev` gets AccessDenied on any EC2/IAM query. The stable
roles themselves have **zero** permissions: they are identities, not
capabilities.

### Decision 3 — DaemonSet vs static pod for the authenticator server

A static pod cannot reference ConfigMaps or ServiceAccounts, which the
DynamicFile mappings ConfigMap requires. The server runs as a **DaemonSet**
pinned to the control plane (nodeSelector + toleration, hostNetwork so the
API server reaches it on localhost); with HA (Sprint 2) it scales to the
3 CPs by itself. Trade-off: between API-server start and DaemonSet
readiness, IAM tokens fail while break-glass keeps working — the
authenticator is never a single point of failure for access.
Backend **DynamicFile** (not EKSConfigMap): avoids the special semantics of
`kube-system/aws-auth` and the authenticator needing its own API/RBAC
access; mappings reload without recreating the control plane.

### Decision 4 — Profiles, not people

The repo declares **access profiles** (`platform/access/profiles.yaml`):
IAM role → Kubernetes groups → RBAC profile (+ namespaces). Mappings and
bindings are rendered from that single file. People never appear in the
repo; onboarding is an Identity Center group membership
(`tofu/envs/identity`), offboarding is its removal.

## Consequences

### Positive

- Short-lived, per-identity credentials with MFA; revocation without
  touching the cluster.
- Real segregation, proven in CI: `developer` operates in `logistics` and
  gets a literal `Forbidden` elsewhere.
- One mechanism for humans and CI; kubeconfigs contain no secrets.

### Negative

- The webhook wiring lives in the sensitive part of `kubeadm init`
  (extraArgs/extraVolumes): misconfiguration breaks API-server start —
  budgeted destroy/recreate verification cycles.
- The Identity Center stack is a second, persistent Tofu lifecycle applied
  manually against the management account.
- Break-glass remains a standing shared-admin credential in SSM (accepted,
  ADR-004).
