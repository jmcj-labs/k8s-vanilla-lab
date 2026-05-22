# ADR-003: CNI Selection — Flannel over Cilium eBPF

**Status**: Superseded (originally Cilium, revised to Flannel)  
**Date**: 2025-05-13 (revised 2025-05-22)  
**Deciders**: Platform Engineering Team

---

## Context

Kubernetes requires a CNI plugin for pod-to-pod communication and Service networking. Two realistic options were evaluated for this lab:

- **Cilium eBPF** — replaces kube-proxy entirely, uses eBPF for O(1) Service lookups, Layer 7 network policies, Hubble observability
- **Flannel + kube-proxy** — VXLAN overlay networking, simple, widely understood, kube-proxy handles Service routing via iptables

The original decision (2025-05-13) chose Cilium. This was revised after bootstrap issues were encountered.

---

## Problem with Original Cilium Decision

Cilium in `kubeProxyReplacement=true` mode requires kube-proxy to be **skipped at kubeadm init time**:

```bash
kubeadm init --skip-phases=addon/kube-proxy
```

This creates a **bootstrap deadlock**:

1. kubeadm skips kube-proxy → no Service IP routing
2. Flannel (or Cilium pre-install) needs to reach `10.96.0.1:443` (kubernetes Service) to contact the API server
3. Without kube-proxy, Service IPs don't resolve → Cilium pod can't start → networking never initializes

Cilium itself cannot break the deadlock because it needs the API server to pull its own config, but the API server is unreachable without Service IP routing.

**Attempted fix**: Install Cilium via `--set k8sServiceHost=<private-IP>` to bypass Service IP. This works in theory but adds manual post-bootstrap steps that defeat the goal of fully automated cloud-init bootstrapping.

---

## Revised Decision

**Use Flannel (VXLAN) + kube-proxy.**

kube-proxy is installed by default (no `--skip-phases` flag), which means Service IPs work immediately after `kubeadm init`. Flannel is then applied automatically within the same cloud-init script:

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

No manual steps. Cluster is fully operational (all nodes `Ready`, pods schedulable) before cloud-init exits.

---

## Consequences

### Positive

- **Zero-touch bootstrap**: Flannel installs automatically, no post-apply manual steps
- **Simplicity**: VXLAN overlay is a foundational concept — ideal for learning CNI internals
- **Reliability**: kube-proxy + iptables is battle-tested and well-understood
- **Debuggability**: Flannel issues are easier to diagnose than eBPF datapath problems

### Negative

- **Performance**: iptables O(n) lookup vs eBPF O(1) — irrelevant at lab scale (<10 Services)
- **No L7 policies**: NetworkPolicies are IP/port only (Layer 3/4)
- **No Hubble**: Less network observability than Cilium
- **Not production-modern**: Real production clusters increasingly use Cilium or Calico eBPF

### When to revisit

If the goal shifts from "learn Kubernetes bootstrapping" to "learn advanced CNI/eBPF networking", replace Flannel with Cilium — but keep kube-proxy installed initially, then migrate to `kubeProxyReplacement=true` as a separate learning exercise after the cluster is stable.

---

## Alternatives Considered

| CNI | Decision | Reason |
|-----|----------|--------|
| Cilium (kube-proxy replacement) | Rejected | Bootstrap deadlock with automated cloud-init |
| Cilium (alongside kube-proxy) | Future option | Works, but defeats Cilium's main advantage |
| Calico eBPF | Not evaluated | Similar complexity to Cilium |
| Flannel + kube-proxy | **Selected** | Simple, reliable, zero-touch bootstrap |
| Weave Net | Not evaluated | Slower, less maintained |

---

## References

- [Flannel GitHub](https://github.com/flannel-io/flannel)
- [kubeadm init phases](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/#init-phases)
- [Cilium kube-proxy replacement](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
