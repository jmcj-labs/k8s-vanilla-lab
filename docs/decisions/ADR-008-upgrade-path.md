# ADR-008: Upgrade path for the network column (S2 piece 4)

**Status**: Accepted (brief #S2-4, ratified by dirección; scope closed)
**Date**: 2026-08-17
**Deciders**: Platform Engineering Team

---

## Context

The piece is named "live Kubernetes upgrade", but the investigation that
preceded it found that is the *third* of three chained upgrades, not the
first. Cilium 1.19 is e2e tested against Kubernetes **1.32–1.35** and does
not cover 1.36; Cilium 1.20 covers **1.33–1.36**. So Kubernetes cannot move
until Cilium does, and Cilium 1.20 in turn documents a newer Gateway API.

Every one of the three touches the **single entry path** crowned in piece 2
(NLB → NodePort 30443 → shared Gateway → app), which is the reason each one
carries its own witness rather than one witness at the end.

## Decision

### 1. Order is contractual — REVISED 2026-08-23 to Gateway API → Cilium → Kubernetes

**The original decision was Cilium → Gateway API → Kubernetes**, on the
reasoning that each movement should change ONE variable and that putting a
new Gateway on an old Cilium would mix two changes in one blast radius. The
reasoning was sound. **The premise was wrong, and executing 4a proved it.**

Cilium 1.20.1 does not merely *document* a newer Gateway API — it **requires**
it. Its operator refuses to start the Gateway API controller without
`gateway.networking.k8s.io/v1` `referencegrants`, `tlsroutes` and
`backendtlspolicies`, none of which exist in v1.2.1. Started in that state it
does not degrade or warn: it logs one error, skips the controller, and every
Envoy that subsequently rolls comes up with no listeners, no routes and no
TLS secret. The entry path died 18 seconds after helm reported success, with
`Gateway Programmed=True` still on screen (INCIDENTS #17, eighth face).

So "Cilium first" was never one variable. It was **Cilium plus the silent
removal of the Gateway control plane** — the largest blast radius of the
three, disguised as the smallest.

**The revised order is `4b → 4a → 4c`:**

| Step | Movement | Why it is safe here |
|------|----------|---------------------|
| **4b** | Gateway API CRDs v1.2 → v1.6, stepped, **on Cilium 1.19.6** | 1.19's controller tolerates newer CRDs; it consumes the versions it knows and ignores the rest. This is the direction that degrades gracefully. |
| **4a** | Cilium 1.19.6 → 1.20.1 | Arrives to CRDs that already satisfy its requirements, so the controller starts and the Gateway keeps a live reconciler. |
| **4c** | Kubernetes 1.35.8 → 1.36.3 | Unchanged: needs Cilium 1.20 for 1.36 coverage. |

This still changes one variable per movement. It just puts them in the order
where each one *can* be a single variable.

**Executing 4b requires proving the controller is ALIVE after every step**,
not that `Programmed` says True — that field is a cache of the last
controller that cared, and it survives the controller's death intact.

### 2. Wait for Cilium 1.20.1 before starting

> **RESUELTO 2026-08-18**: v1.20.1 publicado 10:36Z. La espera duró 20 días
> desde el .0 (cadencia histórica del .1: 13-17 días). Gate abierto.

1.20.0 was released 2026-07-29 with no patches yet. The same discipline the
sprint applies elsewhere — *we do not take as proven what has not been
tested* — applies to the version of the thing that IS our network. Cilium's
observed cadence (patches for three branches on 2026-07-16) suggests days,
not weeks. If execution must start before a patch exists, 1.20.0 is taken
with reinforced validation and a fresh etcd snapshot first.

### 3. Gateway API CRDs are stepped, not jumped — and they go FIRST

Upstream guidance: *"Although it is usually safe to upgrade across multiple
Gateway API minor versions at once, the safest and most widely tested path
will involve upgrading one minor version at a time."* With a Gateway serving
production traffic, we take the tested path: **v1.2.1 → v1.3.0 → v1.4.1 → v1.5.1 → v1.6.1**, on Cilium 1.19.6, one step at
a time, with the witness open across the whole ladder and the controller's
liveness proven after each.

**The channel is HYBRID, and this is the crux** (adjudicated 2026-08-24, and
it corrects a false premise of mine): *required CRDs from the **standard**
channel, plus the **standalone experimental TLSRoute CRD** on top.* Never the
full experimental bundle, which would drag in TCPRoute, UDPRoute and
ServiceImport that we do not use.

Why, verified against the published bundles rather than the docs:

| | `tlsroutes` | `referencegrants` | `backendtlspolicies` |
|---|---|---|---|
| v1.2.1 std (today) | absent | `v1beta1` | absent |
| v1.3.0 std | absent | `v1beta1` | absent |
| **v1.4.1 std** | absent | `v1beta1` | **`v1`** |
| v1.5.1 std | `v1` only | `v1`+`v1beta1` | `v1` |
| v1.6.1 std | `v1` only | `v1`+`v1beta1` | `v1` |
| **experimental TLSRoute alone, v1.6.1** | **`v1`+`v1alpha2`** | — | — |

Our own Cilium 1.19.6 operator states its contract at startup: it *requires*
`v1` gatewayclasses/gateways/httproutes/grpcroutes and **`v1beta1`**
referencegrants, and *optionally* watches **`v1alpha2` tlsroutes**. Cilium
1.20.1 instead requires `referencegrants/**v1**`, `tlsroutes` and
`backendtlspolicies`.

So the only real hazard in the standard channel is that from **v1.5.1** it
ships TLSRoute serving `v1` **only** — dropping the `v1alpha2` that 1.19
watches (cilium/cilium#44920). Overlaying the standalone experimental
TLSRoute CRD keeps `v1alpha2` served while `v1` arrives, so **both Cilium
versions are satisfied simultaneously at v1.6.1** — which is precisely what
makes 4a safe afterwards.

> **Correction, recorded rather than quietly dropped**: an earlier draft of
> this ADR called the standard channel a dead end "because it never brings
> backendtlspolicies". That was false — v1.4.1 standard brings it at `v1`.
> The only genuine problem was losing TLSRoute `v1alpha2` at v1.5.1+, and it
> is solved by the overlay, not by switching the whole bundle.

### 4. Kubernetes target is 1.36.3

Verified in the **apt index our nodes actually install from**
(`pkgs.k8s.io`, v1.36 branch: 1.36.0, 1.36.1, 1.36.2-2.1, 1.36.3), not from
the website — which reported 1.36.2 as latest and was stale. The `-2.1`
packaging suffix on 1.36.2 suggests a re-release; another reason to take .3.

## Two premises corrected by checking the repository

The brief was written on two assumptions that the code does not support.
Both are recorded because they change the risk profile, not to score points:

- **We do NOT use `Gateway.spec.infrastructure`.** The whole of
  `platform/manifests/gateway-shared.yaml` is `gatewayClassName`, one HTTPS
  listener, TLS and `allowedRoutes`; nothing patches it afterwards. The
  v1.2→v1.3 step was flagged as "the sensitive one" because that field
  changed shape — it does not apply to us. The stepped path stays, on
  general prudence rather than that specific risk. **To re-verify against
  the live Gateway**, in case the controller materialises the field at
  runtime.
- **No CiliumNetworkPolicy uses L7 rules.** Cilium 1.20 removes the Envoy Go
  extensions and requires Kafka/L7/L7proto rules under `toPorts[].rules` to
  be deleted before upgrading. `platform/policies/` has none, so this
  breaking change does not touch us. The IMDS policy is L3/L4.

## Strimzi: managed risk, not a blocker

Strimzi 1.1.0 declares no Kubernetes ceiling anywhere we could find — not in
the release notes, the overview, nor the changelog, whose last statement on
the subject is from 0.51: *"we support only Kubernetes 1.30 and newer"*, a
floor. Absence of a declaration is not evidence of incompatibility, so the
decision is to treat it as **managed risk** with a data pre-flight in the
Kubernetes step: drain workers one at a time, observe Kafka Ready after
EACH one, and stop with two healthy brokers if the first broker on a 1.36
kubelet fails. RF3 with `min.insync.replicas=2` survives losing one.

## Consequences

- Three PRs, three cross-reviews, three witnessed windows — not one big move.
- Rollback per step: Cilium 1.19.6 (consecutive minor, supported); the
  v1.2.1 CRD manifest kept ready for the first Gateway API step; and for
  Kubernetes, the HA restore from piece 3, because kubeadm does not support
  a clean minor downgrade.
- The bootstrap is updated at the end so that **new nodes are born
  upgraded** — otherwise the next apply resurrects the old versions.

## References

- Cilium k8s compatibility: https://docs.cilium.io/en/v1.19/network/kubernetes/compatibility/ · https://docs.cilium.io/en/v1.20/network/kubernetes/compatibility/
- Cilium upgrade policy (one minor at a time): https://docs.cilium.io/en/v1.20/operations/upgrade/
- Gateway API CRD management: https://gateway-api.sigs.k8s.io/guides/crd-management/
- Gateway API v1.6.0 release: https://github.com/kubernetes-sigs/gateway-api/releases/tag/v1.6.0
- Kubernetes apt index: https://pkgs.k8s.io/core:/stable:/v1.36/deb/
