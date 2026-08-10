# Incidents — manual platform sprint (2026-08-10)

Findings from the hands-on session that built and validated the evolved
cluster manually, and how each one is now fixed in the repo. Format: what
happened → root cause → fix in IaC/bootstrap.

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

**Fix**: `http_put_response_hop_limit = 2` in `metadata_options` for control
plane and workers ([`tofu/modules/control-plane/main.tf`](../tofu/modules/control-plane/main.tf),
[`tofu/modules/worker/main.tf`](../tofu/modules/worker/main.tf)). IMDSv2
(`http_tokens = "required"`) stays enforced.

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

## 4. IMDS unreachable from the pod network even with hop limit 2

**Symptom**: even after fix #2, pods on the pod network (as opposed to
hostNetwork) still cannot reach 169.254.169.254.

**Root cause**: pending — suspected interaction with Cilium masquerading of
pod egress traffic toward the link-local range.

**Mitigation**: remove the IMDS dependency where it matters — the EBS CSI
controller gets its region explicitly (`--set controller.region=<region>` in
[`platform/install.sh`](../platform/install.sh)) instead of discovering it
via IMDS. Revisit once the masquerading hypothesis is confirmed.
