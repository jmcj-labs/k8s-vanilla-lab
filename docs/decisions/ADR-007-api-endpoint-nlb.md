# ADR-007: HA Control Plane behind the NLB API Endpoint

**Status**: Accepted (brief #S2-3, ratified by dirección + Codex structural review)  
**Date**: 2026-08-16  
**Deciders**: Platform Engineering Team

---

## Context

Until S2 piece 3 the cluster had ONE control plane whose EIP was the API
endpoint (EIP-first pattern), anchored everywhere: kubeadm's
`controlPlaneEndpoint`, worker joins, the SSM kubeconfig, Cilium's
`k8sServiceHost`, CI outputs and Slack. Losing that node meant losing the
cluster — and made piece 4 (live upgrades) impossible.

HA needs two things at once: **3 control planes** (stacked etcd, quorum) and a
**stable API endpoint** that survives any single node. The lab already owns an
internet-facing NLB (S2 piece 2, application entry).

## Decision

1. **The API endpoint is the existing NLB** — new TCP/6443 listener → own
   target group → the 3 CPs as instance targets. kubeadm's
   `controlPlaneEndpoint` is the NLB's DNS, so the API server certs carry that
   SAN and every consumer (CP joins, worker joins, kubeconfigs — SSM and IAM —,
   Cilium agents, kubelets) anchors to it. The app/control-plane **coupling in
   one resource is declared and accepted in this lab**: a bad NLB mutation
   takes both down.
2. **API target group: `preserve_client_ip = false`, PPv2 off** — the CPs are
   *clients* of the endpoint that has them as *targets* (hairpin). AWS
   explicitly discourages client-IP preservation for that topology (a target
   reaching itself sees its own IP as source and the connection fails). The
   application TG keeps `preserve_client_ip = true`. Both are explicit config,
   not defaults.
3. **The CP SG's `0.0.0.0/0:6443` dies** — 6443 is accepted only from the
   NLB's SG (SG→SG reference). The API stays public *by design* (ADR-004: TLS
   + cert/IAM auth, CI runners with dynamic IPs) but on the NLB's SG. The
   negative proof (":6443 answers on no CP public IP") is smoke §14d.
   `api_server_allowed_cidrs` is removed; the EIP with it.
4. **Expectation on record**: the NLB DNS is stable **per incarnation, not
   across destroy/apply** — the `K8S_SERVER` refresh in the handoff runbook
   stays alive alongside `K8S_CA_DATA`. This piece does not change that debt.
5. **Topology: 3× t3.medium on-demand, stacked etcd, ONE AZ.** This is **node
   HA, not zonal HA** — zonal resilience remains declared post-S2 debt. CP-0
   runs `kubeadm init --upload-certs`; CP-1/2 join `--control-plane`
   **sequentially** (kubeadm HA guide requirement), serialized through the SSM
   gate `cp/joined-count`.
6. **CP join material is a security boundary**: `cp/certificate-key` lives in
   an SSM subpath readable by the **CP instance role only**; the worker role
   enumerates exact ARNs (`join-command`, `ca-cert-hash`) — a compromised
   worker holding the certificate-key could elevate itself to control plane
   (Codex finding). The key's 2h TTL is handled by a renewal ceremony
   (`scripts/renew-cp-certificate-key.sh` + runbook): a surviving CP re-runs
   `upload-certs` and publishes a fresh key; replacements re-fetch on retry.

## Consequences

### Positive

- The cluster survives losing any control plane, including the founder —
  drilled as acceptance (loss drill, replacement drill, HA restore drill).
- One public door for everything: app :443 and API :6443, both SG-scoped
  end to end; no node IP is an endpoint anymore.
- Prerequisite for piece 4 (live upgrades) is in place.

### Negative / accepted

- **Declared coupling**: NLB mutations affect app AND API (lab-acceptable).
- **+~2.7–2.9 $/day** (2 extra on-demand CPs, 2 public IPv4, 60 GiB gp3) —
  real number to be fixed from Cost Explorer after first apply (CLUSTER.md
  §FinOps).
- Node HA only: an AZ outage still kills the cluster (post-S2 debt).
- etcd restore becomes a *logical cluster reconstruction*
  (RUNBOOK-restore-etcd-ha.md, with `etcdutl --bump-revision
  --mark-compacted` per etcd 3.6 guidance); the single-CP runbook is
  historical.

## Alternatives considered

| Option | Decision | Reason |
|--------|----------|--------|
| Second, dedicated NLB for the API | Rejected | ~2× NLB cost for a lab; the coupling is acceptable and DECLARED instead |
| Route53 + health-checked A records as endpoint | Rejected | Brief exclusion (no Route53); DNS TTL failover is slower and adds a zone to manage |
| keepalived/kube-vip VIP on the CPs | Rejected | A VIP in a single subnet adds moving parts without removing the single-AZ limitation |
| Keep 1 CP, snapshot-restore on loss | Rejected | That is piece 1's posture; it cannot host live upgrades (piece 4) and restore is minutes of downtime |
| External etcd cluster | Rejected | 3 more instances and a second failure domain to operate; stacked is the kubeadm default and enough for the lab |

## References

- kubeadm HA topology & sequential joins: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/
- NLB client-IP preservation caveats (hairpin): https://docs.aws.amazon.com/elasticloadbalancing/latest/network/edit-target-group-attributes.html#client-ip-preservation
- etcd 3.6 restore guidance (`--bump-revision`, `--mark-compacted`): https://etcd.io/docs/v3.6/op-guide/recovery/
- ADR-004 (kubeconfig via SSM — amended), brief #S2-2 (NLB), INCIDENTS #6/#11
