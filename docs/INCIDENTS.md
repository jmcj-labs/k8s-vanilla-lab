# Incidents — platform sprint (2026-08-10)

Findings 1-4 come from the hands-on session that built the evolved cluster
manually; findings 5-7 from automating it (CI apply runs the same day).
Format: what happened → root cause → fix in IaC/bootstrap.

## 1. Multi-line paste with `apt-get` consumed stdin

**Symptom**: pasting multi-line command blocks into an SSH session silently
skipped lines; `apt-get` (and other interactive-capable tools) read the rest
of the pasted block from stdin, so subsequent commands never executed.

**Root cause**: interactive tools consume stdin; a pasted block is stdin.

**Fix**: never drive the cluster by pasting blocks. All procedures live in
scripts executed as files with `set -euxo pipefail` so every line runs, echoes
and fails loudly ([`platform/install.sh`](../platform/install.sh),
[`scripts/smoke-test.sh`](../scripts/smoke-test.sh), bootstrap scripts).

## 2. IMDSv2 hop limit 1 blocked pods from reaching instance metadata

**Symptom**: the EBS CSI driver could not reach IMDS from its pods; metadata
requests timed out.

**Root cause**: with `http_put_response_hop_limit = 1`, the IMDSv2 PUT
response dies at the first network hop, and traffic from containers crosses
one extra hop.

**Fix**: raising the hop limit in `metadata_options` for control plane and
workers ([`tofu/modules/control-plane/main.tf`](../tofu/modules/control-plane/main.tf),
[`tofu/modules/worker/main.tf`](../tofu/modules/worker/main.tf)). IMDSv2
(`http_tokens = "required"`) stays enforced. The manual sprint raised it to 2,
which was still one hop short — see incident #4 for the final value (3) and
the real root cause.

## 3. Empty providerID on kubeadm-vanilla nodes broke the EBS CSI driver

**Symptom**: volume provisioning failed; the EBS CSI controller could not map
nodes to EC2 instances.

**Root cause**: kubeadm without a cloud provider leaves `spec.providerID`
empty, and the EBS CSI driver requires it (`aws:///<az>/<instance-id>`) as its
metadata source.

**Fix**: every node (CP and workers) passes `--provider-id` to the kubelet
**before** `kubeadm init`/`join` via `/etc/default/kubelet`, written by
[`bootstrap/common.yaml`](../bootstrap/common.yaml) (Step 7b) with AZ +
instance-id read from IMDSv2 — the kubelet publishes it at node registration.
Chosen over the post-init/post-join `kubectl patch` validated in the manual
run because it is one mechanism for all nodes, needs no cluster credentials
on workers and no reconciler on the CP. The smoke test asserts providerID is
non-empty on every node.

## 4. IMDS unreachable from the pod network even with hop limit 2 — RESOLVED

**Symptom**: even after fix #2, pods on the pod network (as opposed to
hostNetwork) still cannot reach 169.254.169.254. In the automated cluster this
crashed the entire EBS CSI driver: the controller could not fetch
instance-profile **credentials** ("no EC2 IMDS role found … context deadline
exceeded") and the node plugin could not fetch metadata (its `kubernetes`
fallback also fails — it needs topology labels that vanilla kubeadm does not
set, not just providerID).

**Root cause (confirmed 2026-08-10, CI diagnostics)**: Cilium runs in tunnel
routing mode with iptables masquerade. Pod egress to IMDS is SNATed to the
node IP, but the IMDS response TTL crosses one more routing hop on the way
back to the pod than a plain container bridge — hop limit 2 is exactly one
short. It was never link-local masquerade exclusion (`bpf ipmasq` unused;
the `CILIUM_POST` MASQUERADE rule covers non-cluster destinations).

**Fix**: `http_put_response_hop_limit = 3` on CP and workers. Verified by a
fresh CI apply: EBS CSI healthy, dynamic gp3 PVC Bound + mounted. The
explicit `--set controller.region` in
[`platform/install.sh`](../platform/install.sh) stays as defense in depth.

**Security debt (priority)**: hop 3 makes IMDS (and the node's instance
profile) reachable from ANY pod, not just the EBS CSI. Before running
untrusted workloads, add a CiliumNetworkPolicy allowing 169.254.169.254 only
from the EBS CSI pods and denying it for the rest of the pod network.
**→ Paid on 2026-08-11**: `platform/policies/ccnp-deny-imds.yaml`
(clusterwide egressDeny, EBS CSI excluded from the endpointSelector),
verified by the smoke with Hubble drop evidence.

## 5. Gzip cloud-init passed as plain `user_data` broke in-place updates

**Symptom**: the first apply that modified live instances in place
(`metadata_options` change) aborted with `Provider produced inconsistent
final plan … Value is base64 encoded … use the user_data_base64 argument`.

**Root cause**: `cloudinit_config` renders gzip+base64, but both modules
passed it to `aws_instance.user_data`, which expects plain UTF-8 — a
contract violation that stayed invisible while instances were only ever
created, never updated.

**Fix**: both modules use `user_data_base64`
([`tofu/modules/control-plane/main.tf`](../tofu/modules/control-plane/main.tf),
[`tofu/modules/worker/main.tf`](../tofu/modules/worker/main.tf)), with
`user_data` kept in `ignore_changes` to absorb the attribute migration.

## 6. Inline + standalone rules on the same security group wiped a rule

**Symptom**: the aborted apply from #5 still "completed" the CP security
group modification — deleting the worker→CP allow rule in AWS on a live
cluster.

**Root cause**: the CP SG declared inline `ingress` blocks while the worker
module attached a standalone rule to the same SG. Inline rules are enforced
as the complete set: any apply deletes externally attached rules. (The inline
"All from workers" rule was also mislabeled — `self = true` allows CP→CP,
not worker→CP.)

**Fix**: the CP SG has no inline rules; every rule is a standalone
`aws_vpc_security_group_ingress_rule`/`egress_rule`, including the worker→CP
rule owned by the worker module. Never mix inline and standalone rules on
one SG.

## 7. Gateway never `Programmed` without a LoadBalancer implementation

**Symptom**: `shared-gw` reached `Accepted=True` but `Programmed` timed out;
its generated LoadBalancer Service stayed `Pending` forever.

**Root cause**: no cloud-controller-manager in a kubeadm-vanilla cluster →
nothing assigns LoadBalancer IPs, and Cilium only programs a Gateway once its
Service has an address.

**Fix**: a `CiliumLoadBalancerIPPool`
([`platform/manifests/lb-ipam-pool.yaml`](../platform/manifests/lb-ipam-pool.yaml))
scoped to namespace `infra` — Cilium LB-IPAM assigns a virtual IP
(`172.20.255.0/24`, not announced externally) and the Gateway programs.
External access remains via NodePort until the Sprint 2 ingress decision
(NLB).

## 8. A deny-only Cilium policy blacked out the whole cluster's egress

**Symptom**: right after applying the clusterwide IMDS deny, the smoke's gp3
PVC never bound. Live diagnosis: the EBS CSI controller could not resolve
`ec2.eu-west-1.amazonaws.com`; CoreDNS logged i/o timeouts to its upstream
(10.0.0.2); Hubble showed **Policy denied DROPPED** from CoreDNS to both the
VPC resolver and the API server. Every pod except the EBS CSI had lost all
egress.

**Root cause**: in Cilium, a policy containing ONLY deny rules still flips
the selected endpoints into **default-deny** for that direction. The CCNP
selected every endpoint except the CSI with an `egressDeny` — so everything
else's egress became "deny everything", not "deny just IMDS".

**Fix**: `enableDefaultDeny: {egress: false, ingress: false}` on the CCNP —
the documented switch that turns a policy into a pure deny overlay
([`platform/policies/ccnp-deny-imds.yaml`](../platform/policies/ccnp-deny-imds.yaml)).
Verified live: DNS recovered instantly, IMDS still denied with
`Policy denied by denylist` drops, CSI exception intact.

**Bonus finding (smoke flakiness)**: `hubble observe | grep -q` under
`set -o pipefail` is racy — `grep -q` exits on first match, the writer can
catch SIGPIPE, and the pipeline (inside `if`) reads as false. The smoke now
captures output first and greps the variable, plus uses precise `--from-pod`
filters instead of fishing in the last-N global drops.

## 9. Kafka under network policy: three traps found live (phase 2)

**Symptom(s)**: (a) the entity operator stayed Pending forever and the Kafka
CR never went Ready; (b) after fixing that, a neutral-namespace pod could
still reach the brokers on 9093 despite the operand CNP; (c) after a broker
restart, that broker never became Ready and operator reconciliation stalled.

**Root causes** (each pinned with live evidence, not theory):

1. **Label spillover**: Strimzi puts `strimzi.io/cluster` (and `kind=Kafka`)
   on the entity operator too. Both the required anti-affinity and the CNP
   endpointSelector must use `strimzi.io/pool-name` — the only label
   exclusive to the broker/controller pods — or the entity operator gets
   repelled off every worker / strangled by the operand default-deny.
2. **Strimzi generates its own per-listener NetworkPolicy, open to ANY** —
   and network policies compose by union of allows, so the generated
   `ANY:9093` defeats the CNP's scoping (seen as `Allow Ingress ANY
   9093/TCP` in the BPF policy map). The listener's `networkPolicyPeers`
   is the supported way to scope it (to `logistics`).
3. **Brokers need egress to the API server and ingress 8443 from the
   cluster operator (KafkaAgent)** — Hubble showed the restarted broker
   dropping SYNs to kube-apiserver under the CNP's default-deny, and the
   operator timing out reading broker configs. The CNP now includes both,
   self-sufficient instead of leaning on Strimzi's generated policy.

**Fix**: pool-name selectors everywhere, `networkPolicyPeers` on the
listener, `toEntities: kube-apiserver` + operator 8443 in
[`cnp-data-kafka.yaml`](../platform/policies/cnp-data-kafka.yaml). Verified
by the full smoke: RF3 produce/consume from logistics, broker-loss
tolerance, neutral namespace denied with Hubble drops.

## 10. Egress to the Gateway VIP is not gated by a client-side network policy

**Symptom**: building the app contract (brief 3b entregable 5b), a
CiliumNetworkPolicy meant to allow ONLY `traffic-generator` pods egress to
the shared Gateway (`toEntities: [ingress]`, TCP/443) neither restricted nor
was needed. Live fixture proof: a `logistics` pod WITH the label reached the
Gateway (HTTP 200) — and so did a pod WITHOUT it (HTTP 200). The intended
negative assertion could never pass.

**Root cause**: traffic to the Cilium Gateway LoadBalancer VIP is
`to-proxy` redirected to the built-in Envoy at the datapath BEFORE the pod's
L3/L4 egress policy toward the destination is evaluated. Hubble shows the
destination as `reserved:world` with verdict `to-proxy FORWARDED`, and the
endpoint's realized BPF policy carries no matching egress allow. The
`reserved:ingress` identity governs INGRESS from Envoy to the backend (which
is why the `logistics` default-deny opens `fromEntities: [ingress]`), not the
client's egress to the Gateway. Control confirmed the default-deny itself
works: the same pod to another `world` IP (1.1.1.1:443) times out.

**Fix**: remove the client-side egress CNP (it is a no-op) and keep the
smoke fixture positive-only — "a `logistics` pod reaches the Gateway over
HTTPS with SNI". No `world`/`host`/`cluster` shortcut was taken, per the
brief's tripwire.

Note on `allowedRoutes`: it controls **route ownership** (which namespaces
may attach HTTPRoutes to the Gateway — scoped to `logistics` here), NOT
**request authorization** (which client pods may send requests through the
Gateway). So it does not substitute for the missing egress control. Risk
accepted for the MVP: there is no requirement to isolate clients *within*
`logistics` from each other. The real future control is L7/auth at the
Gateway plus per-service network policies — Phase 1.5 (CLUSTER.md §5).

## 11. `count`/`for_each` on unknown values — latent until a plan from empty state

**Symptom**: after the cluster was destroyed, the first `tofu plan` against the
now-empty state failed:
`Error: Invalid count argument … count value depends on resource attributes
that cannot be determined until apply` at
`modules/registry/main.tf:161`. Every prior PR's Validate had passed —
because the resources already existed in state, so the values the `count`
read were known. Nothing in the code had changed; only the state emptied.

**Root cause**: `count = var.developer_role_arn != "" ? 1 : 0`, where
`developer_role_arn` comes from `module.access` and is **unknown-after-apply**
on a create-from-scratch plan. OpenTofu forbids `count`/`for_each` depending
on a value not known until apply — it cannot expand the resource. Same family
as the fresh-safe trust of PR #36 and INCIDENTS' recurring theme: **the graph
does not plan from zero**. Bugs that only touch known-after-apply values stay
invisible as long as the state is populated, and surface the moment you plan
against an empty state — i.e. exactly at the coronation apply.

**Fix**: gate the `count` on a STATIC boolean (`attach_assume_developer`,
known at plan), keeping `developer_role_arn` only as the policy **Resource**
(Resources may be unknown at plan; `count`/`for_each` may not). Swept the
whole graph for the family — the only other candidate,
`worker` `count = length(var.ecr_repository_arns) > 0`, is safe because the
list length is fixed by a static `for_each` even when the ARNs are unknown.

**Guardrail (so the family can never hide again)**: a permanent Validate job
runs `tofu plan` against an **empty local-backend state** (`make plan-empty`),
turning "plans from zero" into a CI invariant. Verified: `47 to add, 0 change,
0 destroy`.
