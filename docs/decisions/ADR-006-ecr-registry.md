# ADR-006: Private ECR registry with immutable tags and split CI roles

**Status**: Accepted
**Date**: 2026-08-12

## Context

The application (`jmcj-labs/logistics-lab`, "Repo 2") needs somewhere to push
its container images and the cluster workers need to pull them privately.
Two candidate registries: GitHub Container Registry (GHCR) and Amazon ECR.

## Decision

**ECR**, in the same account and region as the cluster.

### Registry vs GHCR

- The workers already have an IAM instance role and IMDS reachability — ECR
  pull needs only an IAM policy, no imagePullSecret to distribute or rotate.
  The kubelet `ecr-credential-provider` mints short-lived tokens on demand.
- ECR gives IMMUTABLE tags, scan-on-push and lifecycle policies natively; the
  whole registry is declarative Tofu alongside the rest of the lab.
- GHCR would mean a long-lived pull token as a Kubernetes Secret on the pod
  network — exactly the kind of standing credential this lab avoids.

### Immutable tags, SHA-only

`image_tag_mutability = IMMUTABLE`. Repo 2 tags every image by commit SHA;
`latest` is never used and a tag is never repointed. What a manifest
references is what was built at that SHA, forever — reproducible rollbacks,
no ambiguity about "which image is `:prod` today".

### Split CI roles (separation of duties)

Three distinct principals, none of which can do another's job:

| Principal | Can |
|---|---|
| infra CI role (`k8s-vanilla-lab-github-actions`) | MANAGE the repositories and the `logistics-lab-ci` role declaratively — **no** runtime push/pull |
| `logistics-lab-ci` (this ADR) | push/pull the four repositories, nothing else; trust scoped to `jmcj-labs/logistics-lab` on `main` + release tags |
| worker instance role | pull the four repositories only |

The infra pipeline provisioning the registry must not be able to push
images, and the app pipeline pushing images must not be able to touch
infrastructure. The trust policy uses an exact `sub` list
(`repo:jmcj-labs/logistics-lab:ref:refs/heads/main`, `.../refs/tags/*`) —
never a wildcard that would admit another repo or the whole org.

### force_delete

`force_delete = true`: coherent with the ephemeral lab — `tofu destroy`
removes the repositories AND their images. Documented in CLUSTER.md so it is
never a surprise.

## Consequences

- **Positive**: no pull secrets, no long-lived tokens; reproducible SHA
  images; least privilege across the two repos; registry is code.
- **Negative**: the infra CI role gains a small set of `ecr:*`-management and
  `iam:*` (on exactly `logistics-lab-ci`) permissions — a one-time
  `make bootstrap-aws` is required before the first apply of this change.
- **Note**: the upstream `ecr-credential-provider` binary is no longer
  published to `artifacts.k8s.io` (kubernetes/cloud-provider-aws#1324); the
  staging GCS bucket is the working official source, pinned by version and
  SHA-256 (verified against a real download).
