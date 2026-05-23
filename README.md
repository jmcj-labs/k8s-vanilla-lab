# k8s-vanilla-lab

Kubernetes 1.35 bootstrapped with kubeadm on AWS EC2, automated with OpenTofu and cloud-init.

> **Status:** experimental · learning in public · not for production

[![CI](https://github.com/jmcj-labs/k8s-vanilla-lab/actions/workflows/validate.yml/badge.svg)](https://github.com/jmcj-labs/k8s-vanilla-lab/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![OpenTofu](https://img.shields.io/badge/OpenTofu-1.8.0-623CE4?logo=opentofu)](https://opentofu.org)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.35.5-326CE5?logo=kubernetes)](https://kubernetes.io)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit)](https://pre-commit.com)

---

## Architecture

![Architecture](docs/architecture/architecture.svg)

| Component | Role |
|-----------|------|
| Control plane (t3.medium, on-demand) | kubeadm init, etcd, API server, Elastic IP |
| Worker nodes × 2 (t3.medium, spot) | kubelet, containerd, Flannel agent |
| Internet Gateway + public subnet | Single public subnet, no NAT gateway |
| SSM Parameter Store | Join token, CA cert hash, kubeconfig distribution |
| GitHub Actions (OIDC) | Validate, apply, destroy — no long-lived credentials |
| S3 + DynamoDB | Remote state backend and lock table |

Workers run on spot to keep monthly cost at ~$36. The control plane runs on-demand so the API
server and etcd are never interrupted by spot reclamations. See
[ADR-002](docs/decisions/ADR-002-spot-workers-ondemand-cp.md) for the cost breakdown.

---

## What gets deployed

| Component | Version | Purpose |
|-----------|---------|---------|
| Kubernetes | 1.35.5 | Orchestration platform |
| containerd | 2.2.4 | Container runtime (CRI) |
| kubeadm / kubelet / kubectl | 1.35.5 | Cluster bootstrap and node management |
| Flannel | v0.28.4 | VXLAN overlay CNI |
| kube-proxy | 1.35.5 | Service IP routing (iptables) |
| Ubuntu | 24.04 LTS | Base OS |
| OpenTofu | 1.8.0 | Infrastructure as Code |

Deployment runs in three sequential stages:

| Stage | What happens | Duration |
|-------|-------------|----------|
| 1 — Common bootstrap | containerd, kubeadm, kubelet, AWS CLI installed on all nodes | 3-5 min |
| 2 — Control plane init | `kubeadm init`, Flannel applied, join data and kubeconfig stored in SSM | 5-7 min |
| 3 — Workers join | Workers poll SSM for join token, run `kubeadm join` | 2-3 min |

Total: 8-12 minutes after `make apply` completes.

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| OpenTofu | >= 1.8.0 | [opentofu.org/docs/intro/install](https://opentofu.org/docs/intro/install/) |
| kubectl | any | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| AWS CLI | v2 | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |

AWS one-time setup (S3 state bucket, DynamoDB lock table, OIDC provider, IAM role):
see [docs/bootstrap.md](docs/bootstrap.md).

---

## Quickstart

```bash
# 1. One-time AWS setup (idempotent — safe to re-run)
make bootstrap-aws

# 2. Configure
cp tofu/envs/lab/terraform.tfvars.example tofu/envs/lab/terraform.tfvars
# edit: my_ip (curl ifconfig.me), ssh_key_name, aws_region
cp tofu/envs/lab/backend.hcl.example tofu/envs/lab/backend.hcl
# edit: bucket, region, dynamodb_table

# 3. Deploy (8-12 min for bootstrap to complete)
make init
make apply

# 4. Fetch kubeconfig from SSM and connect
make kubeconfig
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf
kubectl get nodes
```

Full walkthrough, bootstrap monitoring, and day-2 operations:
[docs/walkthrough.md](docs/walkthrough.md).

---

## Cost

| Configuration | Monthly | Notes |
|---------------|---------|-------|
| Lab (default) | ~$36 | 1× On-Demand CP + 2× Spot workers |
| All On-Demand | ~$92 | 2.6× cost, no spot interruptions |
| All Spot | ~$28 | Risky — CP reclamation takes the whole cluster offline |

Based on t3.medium in eu-west-1, 730 hours/month. Destroy when not in use to pay only for hours
used. Full breakdown: [ADR-002](docs/decisions/ADR-002-spot-workers-ondemand-cp.md).

---

## Design decisions

| ADR | Decision | Rationale |
|-----|----------|-----------|
| [ADR-001](docs/decisions/ADR-001-opentofu-vs-terraform.md) | OpenTofu over Terraform | MPL 2.0 license; Linux Foundation governance |
| [ADR-002](docs/decisions/ADR-002-spot-workers-ondemand-cp.md) | Spot workers + On-Demand control plane | 60% cost reduction ($92 → $36/month) without compromising cluster availability |
| [ADR-003](docs/decisions/ADR-003-cilium-ebpf.md) | Flannel + kube-proxy over Cilium eBPF | Cilium caused a bootstrap deadlock in cloud-init; Flannel installs zero-touch |
| [ADR-004](docs/decisions/ADR-004-kubeconfig-ssm.md) | Kubeconfig via SSM | CI smoke test without opening port 22 to runner CIDR |

---

## Known limitations

- **No high availability**: single control plane node; etcd data is lost on termination
- **No backups**: cluster state is ephemeral by design
- **Spot workers**: may be reclaimed with 2-minute notice; instances auto-restart
  (`instance_interruption_behavior = "stop"`) but there is a window where capacity is reduced
- **Bootstrap token TTL**: 24 hours; workers that need to rejoin after the TTL require a new
  token — see [troubleshooting.md](docs/troubleshooting.md#workers-not-joining-the-cluster)
- **cloud-init is first-boot only**: re-running `make apply` on existing instances does not
  re-execute bootstrap scripts; only new instances run the scripts
- **Public subnet, no NAT gateway**: nodes have public IPs; the tradeoff is documented in
  `.trivyignore` (see `AVD-AWS-0164`)
- **Admin kubeconfig in SSM**: full cluster-admin credentials persist until `make destroy`;
  acceptable for a short-lived lab, not for shared or long-lived environments

---

## Development

Pre-commit hooks (tofu fmt, tflint, trivy IaC scan, gitleaks), local prerequisites, and CI
enforcement: [docs/development.md](docs/development.md).

Diagnosis and fixes for common issues:
[docs/troubleshooting.md](docs/troubleshooting.md).

---

## License

MIT — see [LICENSE](LICENSE).
