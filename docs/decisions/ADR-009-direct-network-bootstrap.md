# ADR-009: Bootstrap directly into the target network stack

**Status:** Accepted — 2026-08-27

## Decision

A fresh cluster is born directly with Cilium **1.20.1** and Gateway API
**v1.6.1**. There is no live network upgrade in the path to the initial
state. `kubeadm` omits kube-proxy; Cilium starts with strict kube-proxy
replacement, the API NLB DNS as `k8sServiceHost`, Gateway API and Hubble.

Gateway API is installed before Cilium using the validated hybrid set: six
individual standard CRDs plus the experimental TLSRoute overlay last. All
seven kinds serve `v1`; TLSRoute also serves `v1alpha2`; every CRD carries
bundle version v1.6.1. Bootstrap asserts that live schema before and after
Cilium starts.

## Consequences

The 4b CRD ladder and 4a coordinated Cilium upgrade are no longer deployment
steps for a new lab. They remain production-grade operations material for a
future live-cluster exercise (phase 3), where preserving traffic during an
upgrade is itself the capability under test. ADR-008 remains the history of
the path that validated those components and exposed their ordering
constraints; it is not rewritten as if that work had not happened.
