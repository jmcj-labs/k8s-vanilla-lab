# ADR-003: CNI Selection — Cilium with kube-proxy compatibility mode

**Status**: Accepted — superseded in part by the 2026-08-10 update below
(bootstrap now runs strict kube-proxy replacement)  
**Date**: 2025-05-13 (revised 2026-06-03; updated 2026-08-10)  
**Deciders**: Platform Engineering Team

---

## Context

Kubernetes requires a CNI plugin for pod networking. The lab originally moved away from Cilium
after hitting bootstrap failures in fully automated cloud-init runs.

The failure mode was specific to **Cilium kube-proxy replacement at bootstrap time**:

```bash
kubeadm init --skip-phases=addon/kube-proxy
```

Skipping kube-proxy before Cilium is operational can create a bootstrap deadlock because Service
IP routing is not yet programmed.

---

## Decision

**Use Cilium as the default CNI, while keeping kube-proxy enabled during bootstrap.**

Implementation in control-plane bootstrap:

```bash
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.19.4 \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=false
```

This keeps the bootstrap path zero-touch and avoids the deadlock from kube-proxy-free bring-up,
while still standardizing the cluster on Cilium.

---

## Consequences

### Positive

- **Cilium by default**: modern eBPF data plane and policy engine are available from day 1
- **Reliable bootstrap**: no `--skip-phases=addon/kube-proxy`, so Service routing is available immediately
- **Zero-touch provisioning**: CNI still installs inside cloud-init with no post-apply manual steps
- **Clear migration path**: kube-proxy replacement can be introduced later as a dedicated exercise

### Negative

- **Not yet kube-proxy-free**: full Cilium datapath replacement benefits are deferred
- **Extra moving part**: Helm is needed in bootstrap to install pinned Cilium chart versions
- **Future tuning required**: kube-proxy replacement still needs API host/port wiring and validation

---

## Deferred Follow-up

When the objective shifts to kube-proxy-free operation, treat it as a separate change:

1. bootstrap with kube-proxy enabled remains unchanged for cluster bring-up safety
2. validate kernel compatibility and Cilium readiness on the running cluster
3. migrate to `kubeProxyReplacement=true` with explicit `k8sServiceHost` and `k8sServicePort`

---

## Alternatives Considered

| Option | Decision | Reason |
|--------|----------|--------|
| Cilium with kube-proxy replacement at bootstrap | Rejected for bootstrap default | Deadlock-prone in unattended cloud-init bring-up |
| Cilium with kube-proxy compatibility mode | **Selected** | Meets Cilium objective with reliable automated bootstrap |

---

## Update 2026-08-10 — migrated to strict kube-proxy replacement

The "Deferred Follow-up" above was executed after validating kube-proxy-free
bring-up end to end in a manual sprint. The bootstrap default is now:

- `kubeadm init` with `skipPhases: [addon/kube-proxy]` (InitConfiguration v1beta4)
  — kube-proxy is never installed.
- Cilium 1.19.6 with `kubeProxyReplacement=true` and explicit
  `k8sServiceHost` / `k8sServicePort=6443`, which removes the deadlock that
  motivated compatibility mode: the agent no longer depends on Service
  routing to reach the API server. **Since ADR-007 (S2 piece 3)
  `k8sServiceHost` is the NLB's DNS**, not a control-plane IP — with 3 CPs
  no node address may be the endpoint, and an agent pinned to one node
  would lose the API when that node dies.
- Gateway API standard CRDs (v1.2.1) applied before the Cilium install, with
  `gatewayAPI.enabled=true`, plus Hubble relay/UI.

The compatibility-mode rationale above is kept for historical context.

---

## References

- [Cilium kubeadm installation](https://docs.cilium.io/en/stable/installation/k8s-install-kubeadm/)
- [Cilium kube-proxy replacement](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
- [kubeadm init phases](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/#init-phases)
