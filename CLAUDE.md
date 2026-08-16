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
4. **Modern Stack**: OpenTofu, Cilium CNI, OIDC, cloud-init automation

**Not Goals**:
- Production-ready cluster (no HA, no backups, spot workers)
- Managed Kubernetes (EKS, GKE, AKS)
- Multi-cloud or on-prem support

---

## Tech Stack

| Component | Technology | Version |
|-----------|------------|---------|
| IaC | OpenTofu (NOT Terraform) | 1.8.0 |
| Kubernetes | kubeadm | 1.35.x (latest patch, unpinned) |
| Container Runtime | containerd (Docker repo) | latest (2.3.x at sprint time) |
| CNI | Cilium (strict kube-proxy replacement) | v1.19.6 |
| Gateway API | standard CRDs | v1.2.1 |
| Storage | EBS CSI driver + gp3 default SC | chart 2.63.1 |
| Certificates | cert-manager (+ selfsigned ClusterIssuer) | chart v1.21.1 |
| Data operators | CloudNativePG / Strimzi | charts 0.29.0 / 1.1.0 |
| Monitoring | kube-prometheus-stack | chart 88.2.0 |
| IAM auth | aws-iam-authenticator (DynamicFile, ADR-005) | v0.7.18 |
| Cloud | AWS EC2 | - |
| Bootstrap | cloud-init | - |
| Platform layer | `platform/install.sh` via `make platform` | - |
| CI/CD | GitHub Actions (OIDC) | - |
| OS | Ubuntu 24.04 LTS | - |

**CRITICAL**: Always use `tofu` commands, NOT `terraform`. OpenTofu is used for license and community reasons (see ADR-001).

---

## Repository Structure

```
k8s-vanilla-lab/
├── Makefile                         # Primary local interface — see §6 below
├── scripts/
│   ├── bootstrap-aws.sh            # One-time AWS setup (S3, DynamoDB, OIDC, IAM)
│   └── smoke-test.sh               # Cluster + platform verification (invoked by make smoke-test)
├── platform/
│   ├── install.sh                  # Ordered, idempotent platform install (make platform)
│   ├── README.md                   # Components, versions, execution model
│   └── manifests/                  # namespaces, gp3 SC, ClusterIssuer, shared Gateway
├── tofu/
│   ├── modules/
│   │   ├── control-plane/          # 3× control plane EC2 (HA, stacked etcd), IAM, security groups
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
│   ├── apply.yml                   # Manual: make apply + 20min wait + make platform + make smoke-test
│   └── destroy.yml                 # Manual dispatch (nightly cron paused during sprint)
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
│   ├── INCIDENTS.md                # Findings from the 2026-08 manual platform sprint
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
- API server: public THROUGH THE NLB only (ADR-007) — the CP SG accepts 6443 solely from the NLB's SG; `api_server_allowed_cidrs` no longer exists
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
| `make kubeconfig` | BREAK-GLASS: fetch admin kubeconfig from SSM → `~/.kube/k8s-vanilla-lab.conf` |
| `make kubeconfig-admin` | IAM-auth kubeconfig (platform-admin role, exec → aws-iam-authenticator) |
| `make kubeconfig-dev` | IAM-auth kubeconfig (developer role, ns logistics only) |
| `make platform` | Fetch kubeconfig (temp file), run `platform/install.sh` (EBS CSI, cert-manager, Gateway, operators, monitoring) |
| `make smoke-test` | Fetch kubeconfig (temp file), run `scripts/smoke-test.sh`: nodes Ready, no kube-proxy, Cilium KPR True, providerID set, gp3 PVC Bound, Gateway Programmed, operators Ready |
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

**Purpose**: HA control plane — 3 nodes with stacked etcd (S2 piece 3, ADR-007)

**Creates**:
- 3× EC2 instances (t3.medium On-Demand, `count = control_plane_count`, auto-assigned public IPs — NO EIP anymore)
- Security group (SSH from `my_ip`; 6443 ONLY from the NLB's SG; etcd/kubelet self-referencing) — ALL rules standalone, never inline (INCIDENTS #6)
- IAM role with SSM write permissions (`/k8s/${cluster_name}/*` — includes the CP-only `cp/` subpath)

**Key Pattern**: NLB-first (replaced the historical EIP-first):
1. The NLB and its DNS depend on NO instance → created first
2. `module.nlb.dns_name` is rendered into every CP/worker-relevant consumer via `templatefile()`
3. Instances boot anchored to the NLB endpoint; index 0 renders `control-plane.yaml` (kubeadm init), indexes 1..N render `control-plane-join.yaml` (SEQUENTIAL control-plane joins, serialized via the SSM gate `cp/joined-count`)
4. API target group attachments (in the NLB module) reference the instance IDs last — resource graph stays acyclic

### tofu/modules/worker

**Purpose**: Worker nodes (default: 2× spot)

**Creates**:
- EC2 instances (t3.medium Spot by default)
- Security group (SSH, kubelet API, Gateway NodePort 30443 from the NLB SG only, pod networking)
- IAM role with SSM read-only permissions
- Bidirectional security group rules with control plane
- `terraform_data` destroy-time provisioner to delete orphaned ENIs created by Kubernetes/CNI components at runtime (not tracked by OpenTofu; would otherwise block security group deletion)

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

**Key Pattern**: Cloud-init per CP index (NLB endpoint rendered in):
```hcl
data "cloudinit_config" "control_plane" {
  count = var.control_plane_count
  # part 1: bootstrap/common.yaml (identical on every node)
  # part 2: index 0 → control-plane.yaml (kubeadm init)
  #         index 1..N → control-plane-join.yaml (sequential CP join)
  # both templated with api_endpoint_dns = module.nlb.dns_name
}
```

---

## Key Design Decisions

### 1. NLB-First Pattern (Stable API Endpoint, ADR-007)

**Problem**: cloud-init needs a stable API endpoint for `controlPlaneEndpoint` before any
instance exists — and with HA no node IP may ever be an endpoint.

**Solution** (replaced the historical EIP-first pattern; the EIP is gone):
1. The NLB (and its DNS + SG) depends on no instance → created first
2. `module.nlb.dns_name` is templated into every bootstrap consumer (kubeadm, Cilium
   `k8sServiceHost`, join command, SSM kubeconfig)
3. CP instances boot anchored to the endpoint; the API TG attachments reference the
   instance IDs last (resource graph acyclic; count from STATIC vars — INCIDENTS #11)

**Code**: `tofu/modules/nlb/main.tf`, `tofu/modules/control-plane/main.tf`

### 2. SSM Parameter Store for Join Data and Kubeconfig

**Why**: Workers need join token and CA cert hash from control plane. CI needs kubeconfig for a
smoke test without opening port 22 to the runner. Joining CONTROL PLANES additionally need the
kubeadm certificate-key — a privilege boundary (it elevates to control plane).

**Parameters stored** (all `SecureString` except the join gate, KMS default key):

| Parameter | Written by | Read by |
|-----------|------------|---------|
| `/k8s/${cluster_name}/join-command` | CP-0 bootstrap | worker bootstrap, CP join bootstrap |
| `/k8s/${cluster_name}/ca-cert-hash` | CP-0 bootstrap | worker bootstrap |
| `/k8s/${cluster_name}/kubeconfig` | CP-0 bootstrap | `make kubeconfig`, `make smoke-test`, CI apply workflow |
| `/k8s/${cluster_name}/cp/certificate-key` | CP-0 bootstrap, renewal ceremony | CP join bootstrap (CP role). EXCLUDED from the worker role — workers enumerate exact ARNs. The CI/OIDC role reads `/k8s/*` and already holds the admin kubeconfig |
| `/k8s/${cluster_name}/cp/joined-count` (String) | each CP after joining | next CP's join gate (sequential joins) |

All parameters are deleted by a destroy-time provisioner on `tofu destroy`. NEVER widen the
worker SSM policy back to the `/k8s/${cluster_name}/*` wildcard — that hands workers the
certificate-key (Codex finding, S2-3).

**Token TTL**: `kubeadm token create --ttl 24h`. Workers that need to rejoin after 24h require a
new token — see `docs/troubleshooting.md`.

### 3. Cilium CNI — strict kube-proxy replacement (Automatic via Bootstrap)

**Mode**: kube-proxy is never installed. `kubeadm init` runs with
`skipPhases: [addon/kube-proxy]` (InitConfiguration v1beta4) and Cilium replaces it entirely.
Validated end-to-end in the 2026-08 manual sprint (see `docs/INCIDENTS.md`).

**Implementation** (`bootstrap/control-plane.yaml`):
- Gateway API standard CRDs v1.2.1 are applied BEFORE the Cilium install (the operator only
  enables its Gateway API controller if the CRDs exist; if Cilium were already installed,
  restart `deploy/cilium-operator` after applying them)
- Cilium installed via Helm:
  ```bash
  helm upgrade --install cilium cilium/cilium --namespace kube-system --version 1.19.6 \
    --set ipam.mode=kubernetes --set kubeProxyReplacement=true \
    --set k8sServiceHost=<NLB DNS> --set k8sServicePort=6443 \
    --set gatewayAPI.enabled=true --set gatewayAPI.externalTrafficPolicy=Cluster --set hubble.relay.enabled=true --set hubble.ui.enabled=true
  ```
- `k8sServiceHost`/`k8sServicePort` MUST stay wired: without them the agent cannot reach the
  API server before Service routing exists (the historical bootstrap deadlock, see ADR-003)
- No manual CNI installation needed after cluster creation

**providerID**: kubeadm leaves `spec.providerID` empty and the EBS CSI driver requires it.
`bootstrap/common.yaml` (Step 7b) writes `--provider-id=aws:///<az>/<instance-id>` (from
IMDSv2) into `/etc/default/kubelet` on every node BEFORE `kubeadm init`/`join`, so the
kubelet publishes it at registration — same mechanism on CP and workers. Never remove it.

### 4. Spot Workers + On-Demand Control Plane

**Why**: 60% cost savings ($92 → $36/month) while maintaining cluster availability.

**Trade-off**: Workers can be reclaimed, but control plane (etcd, API server) is always available.

**See**: ADR-002 for full cost breakdown.

### 5. Kubeconfig via SSM (ADR-004)

**Problem**: CI smoke test needs `kubectl` access after apply. SSH from a runner requires dynamic
security group changes (or opening port 22 to a runner CIDR range).

**Solution**: After `kubeadm init`, bootstrap stores a patched kubeconfig in SSM:
- Path: `/k8s/${cluster_name}/kubeconfig`
- Type: `SecureString` (KMS default key)
- Content: `/etc/kubernetes/admin.conf` with `server:` normalized to the NLB DNS
  (`controlPlaneEndpoint` already points there since ADR-007 — the sed is belt-and-braces)

Locally: `make kubeconfig` fetches it to `~/.kube/k8s-vanilla-lab.conf`.
In CI: `make smoke-test` fetches to a temp file (not persisted to disk), runs
`kubectl get nodes`, exits non-zero if any node is not `Ready`.

**Caveat**: Contains cluster-admin credentials. Acceptable for a short-lived lab. On
`tofu destroy`, a destroy-time provisioner deletes all `/k8s/${cluster_name}/*` parameters
before the IAM role is removed.

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

See `docs/troubleshooting.md` for full diagnostic procedures. Key things an assistant must know
without opening another file:

- **Bootstrap takes 8-12 min after `make apply`**: cloud-init runs in the background. Logs at
  `/var/log/k8s-bootstrap.log`, `/var/log/k8s-cp-bootstrap.log`,
  `/var/log/k8s-worker-bootstrap.log`. Use `make ssh-cp` / `make ssh-worker` to access nodes.
- **cloud-init is first-boot only**: re-running `make apply` on existing instances does not
  re-execute bootstrap scripts. Only new instances run them.
- **Cilium NotReady**: usually resolves 1-2 min after nodes join. Forced re-apply (from any CP
  as root; the endpoint is the NLB DNS — read it from admin.conf, NEVER a node IP):
  `K8S_HOST=$(kubectl --kubeconfig /etc/kubernetes/admin.conf config view -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's|https://(.*):6443|\1|')`
  then `helm upgrade --install cilium cilium/cilium
  --namespace kube-system --version 1.19.6 --set ipam.mode=kubernetes
  --set kubeProxyReplacement=true --set k8sServiceHost=$K8S_HOST
  --set k8sServicePort=6443 --set gatewayAPI.enabled=true
  --set gatewayAPI.externalTrafficPolicy=Cluster --set hubble.relay.enabled=true
  --set hubble.ui.enabled=true`.
- **IMDS from pods**: needs `http_put_response_hop_limit = 3` — Cilium's tunnel routing adds
  one routing hop on the return path, so the container-standard 2 is one short (root cause
  confirmed; see `docs/INCIDENTS.md` #4). Never lower it. The instance-profile exposure this
  creates is CLOSED by policy: a CiliumClusterwideNetworkPolicy in `platform/policies/`
  denies 169.254.169.254 to every pod except the EBS CSI (exception via endpointSelector
  exclusion — deny is not compensable in Cilium). Never remove it.
- **Gateway `Programmed`**: requires an address on its LoadBalancer Service. No cloud LB here —
  Cilium LB-IPAM (`platform/manifests/lb-ipam-pool.yaml`, virtual IPs, ns `infra` only)
  provides it. External application access is the internet-facing NLB (S2-2):
  TCP/443 passthrough to the deterministic NodePort 30443, which only
  answers to the NLB's security group. Grafana is reached via
  `kubectl port-forward` (NodePorts are closed to the outside).
- **providerID**: never remove the kubelet `--provider-id` step in `bootstrap/common.yaml`;
  without it the EBS CSI driver cannot map nodes to instances and PVCs stay Pending.
- **Spot worker disappeared**: auto-restarts within 5-10 min
  (`instance_interruption_behavior = "stop"`). Workers rejoin automatically.
- **Join token TTL is 24h**: workers joining more than 24h after `kubeadm init` need a new
  token. See `docs/troubleshooting.md` for the `kubeadm token create` procedure.
- **`make destroy` may fail with DependencyViolation**: Kubernetes/CNI components create ENIs at runtime
  that OpenTofu doesn't track. Both security groups have `revoke_rules_on_delete = true` and
  `terraform_data` destroy-time provisioners to clean orphaned ENIs automatically. If it still
  fails on older state, see `docs/troubleshooting.md` for manual cleanup commands.
- **Backend config**: `tofu/envs/lab/backend.tf` declares an empty `backend "s3" {}`. Actual
  coordinates in gitignored `backend.hcl` (local) or generated from GitHub Variables in CI.
  Never hardcode backend coordinates into `backend.tf`.

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
3. Document dependencies (e.g., "requires CNI/cluster running first")

---

## References

- **ADRs**: `docs/decisions/`
  - ADR-001: OpenTofu vs Terraform (license, community governance)
  - ADR-002: Spot workers + On-Demand control plane (cost breakdown)
  - ADR-003: Cilium with kube-proxy compatibility mode (safe bootstrap path)
  - ADR-004: Kubeconfig via SSM Parameter Store (CI smoke test without SSH)
- **OpenTofu Docs**: https://opentofu.org/docs/
- **kubeadm Docs**: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/
- **Cilium Docs**: https://docs.cilium.io/
- **cloud-init Docs**: https://cloudinit.readthedocs.io/

---

## Maintenance Notes for AI Assistants

**When updating the Kubernetes series** (patch versions are unpinned — nodes always install
the latest patch of the series in `bootstrap/common.yaml`):
1. Update the apt repo line in `bootstrap/common.yaml`:
   `stable:/v1.35` → `stable:/v1.XX`
2. Update the version table in `README.md` ("What gets deployed")
3. Update CLAUDE.md Tech Stack table

**When updating containerd**: nothing to pin — `common.yaml` installs the latest from the
Docker repo. Update the "at sprint time" mentions in CLAUDE.md / `README.md` if relevant.

**When updating Cilium version**:
1. Update the Helm chart version in `bootstrap/control-plane.yaml`:
   `--version X.Y.Z`
2. Update the re-apply command in `docs/troubleshooting.md` ("Nodes show NotReady")
3. Update the re-apply command in Known Gotchas above (Cilium NotReady bullet)
4. Update CLAUDE.md Tech Stack table and `README.md` ("What gets deployed")

**When updating platform chart versions**:
1. Update the pinned versions at the top of `platform/install.sh`
2. Update the table in `platform/README.md` (kept in sync by convention)
3. Update CLAUDE.md Tech Stack table and `README.md` ("What gets deployed")

**When updating OpenTofu version**:
1. Update `tofu_version` in all three `.github/workflows/*.yml` files
2. Run `make validate` locally with the new version
3. Update CLAUDE.md Tech Stack table and `README.md` prerequisites table

**When updating pre-commit hook versions**:
1. Run `pre-commit autoupdate` — review the diff before committing (major version bumps
   may introduce breaking changes or new findings)
2. Run `pre-commit run --all-files` to verify all hooks pass with updated versions
3. Update `docs/development.md` prerequisites table if install commands change

**When modifying cloud-init templates**:
1. Verify `$${}` escaping for shell variables (see Critical Rules §2)
2. Test templatefile rendering: `tofu console` → `local.control_plane_user_data`
3. Verify bootstrap logs after apply: `/var/log/k8s-*-bootstrap.log`

**When changing infrastructure architecture**:
1. Update `docs/architecture/diagram.py`
2. Regenerate outputs: `cd docs/architecture && python3 diagram.py`
3. Commit `architecture.svg` and `architecture.png` alongside `diagram.py`
4. See `docs/architecture/README.md` for prerequisites (diagrams==0.25.1, graphviz)
