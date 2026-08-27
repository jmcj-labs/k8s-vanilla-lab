# Bootstrap Cloud-Init Variables Interface

This document defines the exact variables passed to each cloud-init template.

## Architecture: DRY Approach (Option B)

- `common.yaml`: Loaded with `file()`, **no variables** (pure install script)
- `control-plane.yaml` (founder, index 0): Receives variables via `templatefile()`
- `control-plane-join.yaml` (indexes 1..N, S2 piece 3): Receives variables via `templatefile()`
- `worker.yaml`: Receives variables via `templatefile()`

---

## 1. common.yaml

**Purpose**: Base installation script for containerd, kubeadm, kubelet, kubectl

**Variables**: NONE (loaded with `file()`, not `templatefile()`)

**Contents**:
- Disable swap
- Install containerd 2.x (version pinned)
- Configure containerd with systemd cgroup driver (config v3 compatible)
- Install kubeadm, kubelet, kubectl (Kubernetes 1.35.5)
- Enable kubelet service
- Configure kernel modules and sysctl for Kubernetes
- NO cloud-init merge directive needed (this is base)

---

## 2. control-plane.yaml (founder, index 0)

**Purpose**: Initialize the Kubernetes control plane with kubeadm, anchored
to the NLB endpoint (ADR-007 — the EIP no longer exists)

**Variables**:
```yaml
cluster_name              # string, e.g., "k8s-vanilla-lab"
aws_region                # string, e.g., "eu-west-1"
pod_cidr                  # string, e.g., "10.244.0.0/16"
service_cidr              # string, e.g., "10.96.0.0/12"
api_endpoint_dns          # string, module.nlb.dns_name (NLB-first pattern)
api_target_group_arn      # string, API target group; registration/healthy gates
ssm_parameter_path        # string, e.g., "/k8s/k8s-vanilla-lab"
```

**Key Operations**:
1. Wait for common.yaml to complete (dependency)
2. aws-iam-authenticator install + `init` (webhook material BEFORE kubeadm)
3. `kubeadm init` with `controlPlaneEndpoint` = `${api_endpoint_dns}:6443`
4. Install Gateway API v1.6.1 hybrid CRDs, then Cilium 1.20.1
   (`k8sServiceHost` = `${api_endpoint_dns}`), asserting the live schema and KPR
5. Capture certificate-key (`upload-certs` phase, validated hex64)
6. Store in SSM:
   - `${ssm_parameter_path}/join-command` = full worker/CP join command (NLB endpoint)
   - `${ssm_parameter_path}/ca-cert-hash` = CA cert hash
   - `${ssm_parameter_path}/api-endpoint` = `${api_endpoint_dns}:6443`
   - `${ssm_parameter_path}/cp/certificate-key` = CP join material (path excluded from the worker role)
   - `${ssm_parameter_path}/kubeconfig` = admin.conf (server = NLB)
7. Open the sequential-join gate: `${ssm_parameter_path}/cp/joined-count` = 1

---

## 2b. control-plane-join.yaml (indexes 1..N)

**Purpose**: Join an additional control plane (stacked etcd), strictly
sequentially

**Variables**:
```yaml
cluster_name              # string
aws_region                # string
api_endpoint_dns          # string, module.nlb.dns_name
ssm_parameter_path        # string
cp_index                  # number, this node's index (1..N)
cp_count                  # number, exact control-plane count
joined_count_library      # string, bootstrap/joined-count.sh injected verbatim
```

**Key Operations**:
1. Wait for common.yaml; authenticator install + `init` (per-node material)
2. Read the gate fail-closed. Missing means wait; unreadable/invalid means fail;
   valid opens only at `max(1, cp_index)`
3. Fetch `join-command` + `cp/certificate-key`
4. `kubeadm join --control-plane --certificate-key ...` with retry +
   key re-fetch (2h TTL → renewal ceremony republishes)
5. Verify local etcd member Running, then publish `cp/joined-count` = index+1

---

## 3. worker.yaml

**Purpose**: Join Kubernetes cluster as worker node

**Variables**:
```yaml
cluster_name              # string, e.g., "k8s-vanilla-lab"
aws_region                # string, e.g., "eu-west-1"
ssm_join_token_path       # string, e.g., "/k8s/k8s-vanilla-lab/join-token"
ssm_ca_cert_hash_path     # string, e.g., "/k8s/k8s-vanilla-lab/ca-cert-hash"
```

**Key Operations**:
1. Wait for common.yaml to complete (dependency)
2. Poll SSM for `join-command` with a wall-clock deadline. Only
   `ParameterNotFound` means wait; any unreadable response fails.
3. Run the retrieved `kubeadm join` command with the explicit CRI socket.
4. Mark as ready

---

## Critical Implementation Notes

### NLB-first endpoint

The NLB DNS is the stable API endpoint. The founder first proves its target
is registered (authorises `kubeadm init`), then proves it is healthy/routed
before the first CRD apply through that endpoint.

### Token Expiry
- Bootstrap tokens expire in 24h (TTL set in kubeadm token create)
- Workers must join within 24h of control plane initialization
- For persistent clusters, implement token rotation or certificate-based join

### SSM Parameter Store
- Control plane writes: `/k8s/${cluster_name}/join-command`, `ca-cert-hash`,
  `api-endpoint`, `kubeconfig`, and the protected `cp/*` join state
- Workers read: same paths
- IAM permissions already configured in modules (control-plane: write, workers: read-only)

### Error Handling
- All scripts MUST use `set -euo pipefail`
- Cloud-init logs: `/var/log/cloud-init-output.log`
- Kubeadm logs: `journalctl -u kubelet`
- Bounded SSM polling uses wall-clock deadlines and per-call CLI timeouts

---

## File References

**Tofu Module**: `tofu/envs/lab/main.tf` (`data.cloudinit_config.control_plane`, one per CP index)

**Control Plane Module**: `tofu/modules/control-plane/main.tf` (NLB-first pattern — the EIP-first pattern was removed in S2 piece 3, ADR-007)

**Bootstrap Files**:
- `bootstrap/common.yaml`
- `bootstrap/control-plane.yaml`
- `bootstrap/control-plane-join.yaml`
- `bootstrap/joined-count.sh`
- `bootstrap/worker.yaml`
