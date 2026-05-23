# CLAUDE.md - AI Context for k8s-vanilla-lab

This file provides complete context for Claude Code (or other AI assistants) to understand and work with this repository effectively.

---

## Project Purpose

**k8s-vanilla-lab** is a **golden path for a vanilla Kubernetes learning lab on AWS** — experimental,
learning in public, not for production.

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
| Kubernetes | kubeadm | 1.35.5 |
| Container Runtime | containerd (Docker repo) | 2.2.4 |
| CNI | Flannel (VXLAN) | v0.28.4 |
| Cloud | AWS EC2 | - |
| Bootstrap | cloud-init | - |
| CI/CD | GitHub Actions (OIDC) | - |
| OS | Ubuntu 24.04 LTS | - |

**CRITICAL**: Always use `tofu` commands, NOT `terraform`. OpenTofu is used for license and community reasons (see ADR-001).

---

## Repository Structure

```
k8s-vanilla-lab/
├── Makefile                         # Primary local interface — see §6 below
├── scripts/
│   └── bootstrap-aws.sh            # One-time AWS setup (S3, DynamoDB, OIDC, IAM)
├── tofu/
│   ├── modules/
│   │   ├── control-plane/          # Control plane EC2, EIP, IAM, security groups
│   │   └── worker/                 # Worker EC2 (spot), IAM, security groups
│   └── envs/
│       └── lab/                    # Main environment: VPC, subnets, IGW, module calls
│           ├── backend.hcl.example # Template for gitignored backend.hcl
│           └── terraform.tfvars.example
├── bootstrap/
│   ├── common.yaml                 # Base: containerd, kubeadm, kubelet (no variables)
│   ├── control-plane.yaml          # kubeadm init, SSM store join data + kubeconfig
│   └── worker.yaml                 # SSM fetch, kubeadm join
├── addons/
│   ├── metrics-server/             # Metrics server manifests
│   └── opencost/                   # OpenCost for cost attribution
├── .github/workflows/
│   ├── validate.yml                # PR + push to main: pre-commit + make validate + plan
│   ├── apply.yml                   # Manual: make apply + 10min wait + make smoke-test
│   └── destroy.yml                 # Nightly cron (0 22 * * *) + manual dispatch
├── docs/
│   ├── architecture/
│   │   ├── diagram.py              # Architecture diagram source (diagrams==0.25.1)
│   │   ├── architecture.svg        # Generated output (primary — renders in GitHub)
│   │   └── architecture.png        # Generated output (fallback)
│   ├── decisions/
│   │   ├── ADR-001-opentofu-vs-terraform.md
│   │   ├── ADR-002-spot-workers-ondemand-cp.md
│   │   ├── ADR-003-cilium-ebpf.md
│   │   └── ADR-004-kubeconfig-ssm.md
│   ├── bootstrap.md                # AWS one-time setup guide
│   ├── development.md              # Pre-commit, tflint, trivy — local dev setup
│   ├── troubleshooting.md          # Diagnostic procedures for common issues
│   └── walkthrough.md              # First deployment step-by-step
├── .pre-commit-config.yaml         # Hook definitions (trailing-ws, tofu-fmt, tflint, trivy, gitleaks)
├── .tflint.hcl                     # tflint config (terraform + aws rulesets)
├── .trivyignore                    # Documented IaC finding exceptions
├── CHANGELOG.md
├── CLAUDE.md                       # This file (AI context)
├── CODEOWNERS
├── CONTRIBUTING.md
├── README.md                       # User-facing documentation
└── SECURITY.md
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

**After ANY `.tf` file modification**, use `make validate`:

```bash
make validate
```

**Do not** run `tofu init` and `tofu validate` directly from the shell. `tofu init` against the S3 backend writes provider and module locks to `.terraform/`; if the backend is inaccessible or the lock is stale, subsequent `tofu validate` may fail or use wrong provider versions. `make validate` avoids this by using `TF_DATA_DIR=$(mktemp -d)` — a fresh temporary directory — so each validation run is hermetic and does not contaminate or depend on any previous init state.

Internally it runs:
```bash
tofu fmt -check -recursive tofu/
VALIDATE_TMP=$(mktemp -d)
cd tofu/envs/lab && TF_DATA_DIR="$VALIDATE_TMP" tofu init -backend=false -input=false
TF_DATA_DIR="$VALIDATE_TMP" tofu validate
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

### 6. Makefile Is the Local Interface

The `Makefile` is the single source of truth for operational commands. **Any process change that applies to CI must also be reflected in the equivalent Makefile target** — and vice versa.

| Target | What it does |
|--------|-------------|
| `make init` | `tofu init -backend-config=backend.hcl` |
| `make validate` | fmt-check + hermetic tofu validate (no S3 backend required) |
| `make fmt` | `tofu fmt -recursive tofu/` |
| `make plan` | `tofu plan` |
| `make apply` | `tofu apply -auto-approve` |
| `make destroy` | `tofu destroy -auto-approve` |
| `make kubeconfig` | Fetch kubeconfig from SSM → `~/.kube/k8s-vanilla-lab.conf` |
| `make smoke-test` | Fetch kubeconfig (temp file), run `kubectl get nodes`, exit non-zero if any NotReady |
| `make ssh-cp` | SSH into control plane |
| `make ssh-worker` | SSH into first worker node |
| `make clean` | Remove `.terraform/` cache and `*.tfstate.backup` |
| `make bootstrap-aws` | One-time: create/verify S3, DynamoDB, OIDC, IAM role |

### 7. OIDC Auth — Never Long-Lived Credentials in CI

The OpenTofu provider is configured with `profile = var.aws_profile`.

| Context | Credential resolution |
|---------|----------------------|
| Local | `aws_profile = "k8s-vanilla-lab"` in `terraform.tfvars`, or `AWS_PROFILE` via `.envrc` + direnv |
| CI | `TF_VAR_aws_profile = ""` (empty default) → provider falls through to `AWS_ACCESS_KEY_ID` / `AWS_SESSION_TOKEN` injected by `aws-actions/configure-aws-credentials` via OIDC |

**NEVER** add long-lived `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` as GitHub Secrets. The OIDC role ARN (`AWS_ROLE_ARN`) is a GitHub **Variable** (not a Secret) — it is a resource identifier, not a credential.

### 8. Pre-Commit Hooks Must Pass

All hooks in `.pre-commit-config.yaml` must pass before any commit is considered done. Key hooks and their language requirements:

| Hook | Language | Install requirement |
|------|----------|-------------------|
| `tofu-fmt` | `system` | `tofu` installed locally |
| `terraform_tflint` | `golang` | auto-installs via antonbabenko/pre-commit-terraform |
| `trivy-config` | `system` | `trivy` installed locally |
| `gitleaks` | `golang` | auto-installs |

`language: system` hooks (`tofu-fmt`, `trivy-config`) require the tools to be installed locally before running. See `docs/development.md` for install instructions. Run `pre-commit run --all-files` before opening a PR.

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
- `terraform_data` destroy-time provisioner to delete orphaned ENIs created by Kubernetes/Flannel at runtime (not tracked by OpenTofu; would otherwise block security group deletion)

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

**Code**: `tofu/modules/control-plane/main.tf`

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
# Copy and configure
cp tofu/envs/lab/terraform.tfvars.example tofu/envs/lab/terraform.tfvars
# Edit: my_ip, ssh_key_name, aws_region
cp tofu/envs/lab/backend.hcl.example tofu/envs/lab/backend.hcl
# Edit: bucket, region, dynamodb_table

# Initialize (first time or after provider changes)
make init

# Review plan (optional)
make plan

# Deploy
make apply

# Wait 8-12 minutes for bootstrap to complete
```

### Get Kubeconfig

Kubeconfig is stored in SSM by the control plane bootstrap script (ADR-004). Do not use the old SSH + `sudo cat /etc/kubernetes/admin.conf` method.

```bash
make kubeconfig
# Saves to ~/.kube/k8s-vanilla-lab.conf

export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf
kubectl get nodes
```

### Destroy Infrastructure

```bash
# Option 1: local
make destroy

# Option 2: GitHub Actions
# Actions → "OpenTofu Destroy" → Run workflow → type "destroy"
# Also runs on nightly cron (0 22 * * *)
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

**Partial backend config**: `tofu/envs/lab/backend.tf` declares `terraform { backend "s3" {} }` with no coordinates. The actual bucket, region, and DynamoDB table are in the gitignored `backend.hcl`. In CI, `backend.hcl` is generated from GitHub Variables. Locally, copy from `backend.hcl.example`.

**NEVER** hardcode backend coordinates directly into `backend.tf`.

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
