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
