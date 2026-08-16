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
ssm_parameter_path        # string, e.g., "/k8s/k8s-vanilla-lab"
```

**Key Operations**:
1. Wait for common.yaml to complete (dependency)
2. aws-iam-authenticator install + `init` (webhook material BEFORE kubeadm)
3. `kubeadm init --upload-certs` with `controlPlaneEndpoint` = `${api_endpoint_dns}:6443`
4. Install Cilium (`k8sServiceHost` = `${api_endpoint_dns}`)
5. Capture certificate-key (`upload-certs` phase, validated hex64)
6. Store in SSM:
   - `${ssm_parameter_path}/join-command` = full worker/CP join command (NLB endpoint)
   - `${ssm_parameter_path}/ca-cert-hash` = CA cert hash
   - `${ssm_parameter_path}/api-endpoint` = `${api_endpoint_dns}:6443`
   - `${ssm_parameter_path}/cp/certificate-key` = CP join material (CP-role-only path)
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
```

**Key Operations**:
1. Wait for common.yaml; authenticator install + `init` (per-node material)
2. Wait for the gate: `cp/joined-count` >= `${cp_index}`
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
kubernetes_version        # string, e.g., "1.35"
ssm_join_token_path       # string, e.g., "/k8s/k8s-vanilla-lab/join-token"
ssm_ca_cert_hash_path     # string, e.g., "/k8s/k8s-vanilla-lab/ca-cert-hash"
```

**Key Operations**:
1. Wait for common.yaml to complete (dependency)
2. Poll SSM for parameters (with retries, max 10 minutes):
   - `JOIN_TOKEN=$(aws ssm get-parameter --name ${ssm_join_token_path} --region ${aws_region} --query 'Parameter.Value' --output text)`
   - `CA_CERT_HASH=$(aws ssm get-parameter --name ${ssm_ca_cert_hash_path} --region ${aws_region} --query 'Parameter.Value' --output text)`
   - `CONTROL_PLANE_ENDPOINT=$(aws ssm get-parameter --name /k8s/${cluster_name}/control-plane-endpoint --region ${aws_region} --query 'Parameter.Value' --output text)`
3. Run `kubeadm join`:
   - `kubeadm join ${CONTROL_PLANE_ENDPOINT} --token ${JOIN_TOKEN} --discovery-token-ca-cert-hash sha256:${CA_CERT_HASH}`
4. Mark as ready

---

## Critical Implementation Notes

### Control Plane Circular Dependency Solution
**Problem**: Control plane needs its EIP in cloud-init, but EIP is created after instance.

**Solution** (already implemented in `tofu/modules/control-plane/main.tf`):
1. Create `aws_eip` resource FIRST (no `instance` argument)
2. Pass `aws_eip.control_plane.public_ip` to `templatefile` for `control-plane.yaml`
3. Create `aws_instance` with user_data from templatefile
4. Create `aws_eip_association` AFTER instance

### Token Expiry
- Bootstrap tokens expire in 24h (TTL set in kubeadm token create)
- Workers must join within 24h of control plane initialization
- For persistent clusters, implement token rotation or certificate-based join

### SSM Parameter Store
- Control plane writes: `/k8s/${cluster_name}/join-token`, `ca-cert-hash`, `control-plane-endpoint`
- Workers read: same paths
- IAM permissions already configured in modules (control-plane: write, workers: read-only)

### Error Handling
- All scripts MUST use `set -euo pipefail`
- Cloud-init logs: `/var/log/cloud-init-output.log`
- Kubeadm logs: `journalctl -u kubelet`
- SSM polling with exponential backoff (10 attempts, 60s wait between)

---

## File References

**Tofu Module**: `tofu/envs/lab/main.tf` lines 85-110 (locals block with templatefile calls)

**Control Plane Module**: `tofu/modules/control-plane/main.tf` lines 148-160 (EIP-first pattern)

**Bootstrap Files** (to be created):
- `bootstrap/common.yaml`
- `bootstrap/control-plane.yaml`
- `bootstrap/worker.yaml`
