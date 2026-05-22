# CLAUDE.md - AI Context for k8s-vanilla-lab

This file provides complete context for Claude Code (or other AI assistants) to understand and work with this repository effectively.

---

## Project Purpose

**k8s-vanilla-lab** is a production-quality **golden path** for deploying vanilla Kubernetes clusters on AWS using **kubeadm**. 

**Goals**:
1. **Learning**: Hands-on Kubernetes bootstrapping with kubeadm, containerd, and cloud-init
2. **Golden Path**: Reusable, documented infrastructure patterns for platform engineers
3. **Cost-Optimized**: Lab cluster for ~$36/month using spot instances
4. **Modern Stack**: OpenTofu, Flannel CNI, OIDC, cloud-init automation

**Not Goals**:
- Production-ready cluster (no HA, no backups, spot workers)
- Managed Kubernetes (EKS, GKE, AKS)
- Multi-cloud or on-prem support

---

## Tech Stack

| Component | Technology | Version |
|-----------|------------|---------|
| IaC | OpenTofu (NOT Terraform) | 1.8.0 |
| Kubernetes | kubeadm | 1.35.x |
| Container Runtime | containerd (Docker repo) | Latest |
| CNI | Flannel (VXLAN) | Latest |
| Cloud | AWS EC2 | - |
| Bootstrap | cloud-init | - |
| CI/CD | GitHub Actions (OIDC) | - |
| OS | Ubuntu 24.04 LTS | - |

**CRITICAL**: Always use `tofu` commands, NOT `terraform`. OpenTofu is used for license and community reasons (see ADR-001).

---

## Repository Structure

```
k8s-vanilla-lab/
├── tofu/
│   ├── modules/
│   │   ├── control-plane/    # Control plane EC2, EIP, IAM, security groups
│   │   └── worker/            # Worker EC2 (spot), IAM, security groups
│   └── envs/
│       └── lab/               # Main environment: VPC, subnets, IGW, module calls
├── bootstrap/
│   ├── common.yaml            # Base: containerd, kubeadm, kubelet (no variables)
│   ├── control-plane.yaml     # kubeadm init, SSM store join data
│   └── worker.yaml            # SSM fetch, kubeadm join
├── addons/
│   ├── metrics-server/        # Metrics server manifests
│   └── opencost/              # OpenCost for cost attribution
├── .github/workflows/
│   ├── tf-validate.yml        # PR checks: tofu validate + plan
│   └── tf-destroy.yml         # Manual destroy with Slack notification
├── docs/decisions/
│   ├── ADR-001-opentofu-vs-terraform.md
│   └── ADR-002-spot-workers-ondemand-cp.md
├── CLAUDE.md                  # This file (AI context)
└── README.md                  # User-facing documentation
```

---

## Critical Rules for AI Assistants

### 1. OpenTofu, Not Terraform

**ALWAYS**:
- Use `tofu` commands (`tofu init`, `tofu plan`, `tofu apply`)
- Reference `opentofu/setup-opentofu@v1` in GitHub Actions
- Use `.tf` file extensions (compatible with Terraform syntax)

**NEVER**:
- Use `terraform` commands
- Reference `hashicorp/setup-terraform` actions
- Mention "Terraform" in new documentation (except when comparing)

### 2. Templatefile Escaping ($${} vs ${})

**In `bootstrap/*.yaml` files that use `templatefile()`**:

- **OpenTofu variables** (passed via templatefile): `${variable_name}`
  ```yaml
  clusterName: ${cluster_name}
  region: ${aws_region}
  ```

- **Shell variables** (set/used in bash): `$${SHELL_VAR}`
  ```bash
  JOIN_TOKEN=$$(kubeadm token create)
  aws ssm put-parameter --value "$${JOIN_TOKEN}"
  ```

- **Command substitutions**: `$(command)` (no escaping)
  ```bash
  certSANs:
    - $(hostname -i)
  ```

**Why**: OpenTofu interprets `${}` as its own variables. Shell variables need `$${}` so OpenTofu passes them through as `${}` at runtime.

### 3. Validation After Changes

**After ANY `.tf` file modification**:
```bash
cd tofu/envs/lab
tofu init -backend=false
tofu validate
```

If validation fails, fix immediately before proceeding.

### 4. No Hardcoded Values

**NEVER hardcode**:
- IP addresses (use variables or data sources)
- AWS ARNs (use data sources or outputs)
- Credentials (use OIDC or IAM roles)
- Region-specific AMI IDs (use `data "aws_ami"` lookup)

**ALWAYS**:
- Use variables with defaults
- Tag all AWS resources with `env`, `project`, `owner`
- Use `module.*.output_name` for cross-module references

### 5. Security Best Practices

- SSH access: restricted to `var.my_ip` only
- API server: restricted to `var.my_ip` by default (expandable via `api_server_allowed_cidrs`)
- IAM policies: minimal scope (`/k8s/${cluster_name}/*` for SSM)
- IMDSv2: enforced on all EC2 instances
- EBS encryption: enabled by default

---

## Module Responsibilities

### tofu/modules/control-plane

**Purpose**: Single control plane node with kubeadm

**Creates**:
- EIP (created FIRST to avoid circular dependency with templatefile)
- EC2 instance (t3.medium On-Demand)
- Security group (SSH, K8s API, etcd, kubelet)
- IAM role with SSM write permissions (`/k8s/${cluster_name}/*`)

**Key Pattern**: EIP-first pattern:
1. `aws_eip.control_plane` (no instance dependency)
2. Pass `aws_eip.control_plane.public_ip` to `templatefile()` for `control-plane.yaml`
3. `aws_instance.control_plane` uses templated user_data
4. `aws_eip_association.control_plane` associates EIP to instance

### tofu/modules/worker

**Purpose**: Worker nodes (default: 2× spot)

**Creates**:
- EC2 instances (t3.medium Spot by default)
- Security group (SSH, kubelet API, NodePorts, pod networking)
- IAM role with SSM read-only permissions
- Bidirectional security group rules with control plane

**Key Feature**: `capacity_type` variable:
- `"spot"` (default): 70% cost savings, can be reclaimed
- `"on-demand"`: Full availability, no interruptions

### tofu/envs/lab

**Purpose**: Orchestrates modules + networking

**Creates**:
- VPC (dedicated, not default VPC)
- Public subnet + Internet Gateway (no NAT Gateway for cost)
- Data source for latest Ubuntu 24.04 LTS AMI
- Calls control-plane and worker modules
- Loads cloud-init templates via `templatefile()` and `file()`

**Key Pattern**: Cloud-init DRY approach:
```hcl
locals {
  common_user_data = file("${path.module}/../../../bootstrap/common.yaml")
  
  control_plane_user_data = templatefile("${path.module}/../../../bootstrap/control-plane.yaml", {
    cluster_name            = var.cluster_name
    control_plane_public_ip = module.control_plane.public_ip
    # ... more variables
  })
}
```

---

## Key Design Decisions

### 1. EIP-First Pattern (Solves Circular Dependency)

**Problem**: Control plane needs its EIP in cloud-init for kubeadm SAN, but EIP creation depends on instance ID.

**Solution**:
1. Create EIP without instance association
2. Pass EIP public IP to templatefile
3. Create instance with templated user_data
4. Associate EIP to instance after creation

**Code**: `tofu/modules/control-plane/main.tf` lines 148-217

### 2. SSM Parameter Store for Join Data

**Why**: Workers need join token and CA cert hash from control plane.

**Flow**:
1. Control plane runs `kubeadm init`
2. Generates token: `kubeadm token create --ttl 24h`
3. Stores in SSM: `/k8s/${cluster_name}/join-command`, `ca-cert-hash`, `api-endpoint`
4. Workers poll SSM until parameters exist (15min timeout)
5. Workers fetch and execute join command

**Security**: All parameters use `SecureString` type (encrypted with KMS).

### 3. Flannel CNI (Automatic via Bootstrap)

**Why**: Flannel is simple, well-understood VXLAN overlay networking ideal for learning Kubernetes networking concepts.

**Implementation**:
- kube-proxy is installed normally (required by Flannel for service IP routing)
- `bootstrap/control-plane.yaml` runs `kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml` automatically
- No manual CNI installation needed after cluster creation

**Key**: Flannel requires kube-proxy. Never skip kube-proxy phase when using Flannel (`--skip-phases=addon/kube-proxy` was removed).

### 4. Spot Workers + On-Demand Control Plane

**Why**: 60% cost savings ($92 → $36/month) while maintaining cluster availability.

**Trade-off**: Workers can be reclaimed, but control plane (etcd, API server) is always available.

**See**: ADR-002 for cost breakdown

---

## Common Tasks

### Apply Infrastructure

```bash
cd tofu/envs/lab

# Create terraform.tfvars
cp terraform.tfvars.example terraform.tfvars
# Edit: my_ip, ssh_key_name

# Initialize (first time only)
tofu init

# Plan and review
tofu plan

# Apply
tofu apply

# Wait 8-12 minutes for bootstrap to complete
```

### Get Kubeconfig

```bash
# From tofu output
CONTROL_PLANE_IP=$(tofu output -raw control_plane_public_ip)

# Extract kubeconfig
ssh -i ~/.ssh/k8s-vanilla-lab.pem ubuntu@${CONTROL_PLANE_IP} \
  'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/k8s-vanilla-lab.conf

# Fix server URL to use public IP (kubeadm writes private IP by default)
sed -i.bak "s|server: https://.*:6443|server: https://${CONTROL_PLANE_IP}:6443|" ~/.kube/k8s-vanilla-lab.conf

# Point kubectl to this config
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf

# Verify - nodes should be Ready (Flannel installed automatically)
kubectl get nodes
```

**Tip**: Use the `k8s-config` shell alias (defined in `~/.zshrc`) which does all of the above in one command.

### Destroy Infrastructure

**Option 1: GitHub Actions (Recommended)**
1. Go to Actions tab → "OpenTofu Destroy"
2. Click "Run workflow"
3. Type "destroy" in confirmation field
4. Slack notification sent on completion

**Option 2: Manual**
```bash
cd tofu/envs/lab
tofu destroy
```

---

## Known Gotchas

### Bootstrap Timing

**Total time**: 8-12 minutes after `tofu apply` completes

**Breakdown**:
- common.yaml (containerd, kubeadm install): ~3-5 min
- control-plane.yaml (kubeadm init, SSM store): ~5-7 min
- worker.yaml (SSM poll, kubeadm join): ~2-3 min

**How to check**:
```bash
# Control plane
ssh ubuntu@${CONTROL_PLANE_IP}
sudo tail -f /var/log/k8s-bootstrap.log       # Common bootstrap
sudo tail -f /var/log/k8s-cp-bootstrap.log   # Control plane init

# Workers
ssh ubuntu@${WORKER_IP}
sudo tail -f /var/log/k8s-bootstrap.log       # Common bootstrap
sudo tail -f /var/log/k8s-worker-bootstrap.log # Worker join
```

### Spot Worker Interruptions

**Symptom**: Worker node disappears from `kubectl get nodes`

**Cause**: AWS reclaimed spot instance (2-minute notice)

**Fix**: Spot instances auto-restart (instance_interruption_behavior = "stop"), but may take 5-10 minutes to rejoin cluster

**Prevention**: Set `worker_capacity_type = "on-demand"` in `terraform.tfvars` for critical workloads

### Flannel Not Ready / Pods Stuck in ContainerCreating

**Symptom**: Pods stuck in `ContainerCreating`, nodes show `NotReady`

**Cause**: Flannel hasn't finished initializing (usually resolves within 1-2 min of cluster creation)

**Check**:
```bash
kubectl get pods -n kube-flannel
kubectl logs -n kube-flannel -l app=flannel --tail=20
```

**Fix** (if Flannel pods are crashing):
```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

### SSH Connection Failures

**Symptom**: `ssh: connect to host X port 22: Connection refused`

**Cause**: Bootstrap still running, SSH service not ready yet

**Fix**: Wait 2-3 minutes after `tofu apply`, then retry

### Backend Configuration

**For CI/CD**: Use `-backend=false` in GitHub Actions

**For real usage**: Update `tofu/envs/lab/backend.tf` with your S3 bucket and DynamoDB table

---

## Extending This Project

### Adding a New Environment (e.g., prod)

1. Copy `tofu/envs/lab` → `tofu/envs/prod`
2. Update `terraform.tfvars` with prod-specific values
3. Change `worker_capacity_type = "on-demand"` (no spot for prod)
4. Use separate backend S3 key: `key = "k8s-vanilla-prod/terraform.tfstate"`

### Adding New Cloud-Init Steps

**To common.yaml** (affects all nodes):
- Add to `runcmd` section
- Test on both control plane and workers

**To control-plane.yaml** (control plane only):
- Add after `kubeadm init` completes
- Ensure idempotency (can re-run safely)

**To worker.yaml** (workers only):
- Add after `kubeadm join` completes
- Workers run in parallel, so avoid shared resources

### Adding New Addons

1. Create `addons/my-addon/README.md` with installation instructions
2. Include Helm chart or kubectl manifests
3. Document dependencies (e.g., "requires Flannel/cluster running first")

---

## References

- **ADRs**: `docs/decisions/` (design decisions and alternatives)
- **OpenTofu Docs**: https://opentofu.org/docs/
- **kubeadm Docs**: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/
- **Flannel Docs**: https://github.com/flannel-io/flannel
- **cloud-init Docs**: https://cloudinit.readthedocs.io/

---

## Maintenance Notes for AI Assistants

**When updating Kubernetes version**:
1. Update `kubernetes_version` local in `tofu/envs/lab/main.tf`
2. Update `bootstrap/common.yaml` Kubernetes repo version (v1.35 → v1.XX)
3. Test bootstrap on fresh cluster
4. Update README.md version table

**When updating OpenTofu version**:
1. Update `.github/workflows/*.yml` `tofu_version` field
2. Test `tofu validate` locally
3. Update README.md prerequisites

**When modifying cloud-init templates**:
1. Verify `$${}` escaping for shell variables
2. Test templatefile rendering: `tofu console` → `local.control_plane_user_data`
3. Verify bootstrap logs after apply: `/var/log/k8s-*-bootstrap.log`
