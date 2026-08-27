# k8s-vanilla-lab

Kubernetes 1.35 bootstrapped with kubeadm on AWS EC2, automated with OpenTofu and cloud-init.

> **Status:** experimental · learning in public · not for production

[![CI](https://github.com/jmcj-labs/k8s-vanilla-lab/actions/workflows/validate.yml/badge.svg)](https://github.com/jmcj-labs/k8s-vanilla-lab/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![OpenTofu](https://img.shields.io/badge/OpenTofu-1.8.0-623CE4?logo=opentofu)](https://opentofu.org)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.35-326CE5?logo=kubernetes)](https://kubernetes.io)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit)](https://pre-commit.com)

---

## Architecture

![Architecture](docs/architecture/architecture.svg)

| Component | Role |
|-----------|------|
| Control planes × 3 (t3.medium, on-demand) | HA with stacked etcd (node HA, single AZ — ADR-007); kubeadm init on CP-0, sequential control-plane joins |
| Worker nodes × 3 (t3.medium, spot) | kubelet (with `--provider-id`), containerd, Cilium agent |
| NLB (internet-facing, single door) | TCP/443 passthrough → Gateway NodePort AND TCP/6443 → API servers (`controlPlaneEndpoint`) |
| Cilium (kube-proxy replacement) | eBPF datapath, Service routing (no kube-proxy), Gateway API, Hubble |
| Platform layer (`platform/`) | EBS CSI + gp3 default SC, cert-manager, shared Gateway, CNPG + Strimzi operators, kube-prometheus-stack |
| Internet Gateway + public subnet | Single public subnet, no NAT gateway |
| SSM Parameter Store | Join token, CA cert hash, kubeconfig distribution |
| GitHub Actions (OIDC) | Validate, apply (+ platform + smoke), destroy — no long-lived credentials |
| S3 + DynamoDB | Remote state backend and lock table |

Workers run on spot; the control planes run on-demand so the API servers and etcd quorum are
never interrupted by spot reclamations. See
[ADR-002](docs/decisions/ADR-002-spot-workers-ondemand-cp.md) for the original cost rationale
and [ADR-007](docs/decisions/ADR-007-api-endpoint-nlb.md) for the HA topology (~7.1 $/day
running — CLUSTER.md §FinOps holds the measured number).

---

## What gets deployed

| Component | Version | Purpose |
|-----------|---------|---------|
| Kubernetes | 1.35.x (latest patch) | Orchestration platform |
| containerd | latest from Docker repo (2.3.x) | Container runtime (CRI) |
| kubeadm / kubelet / kubectl | 1.35.x (latest patch) | Cluster bootstrap and node management |
| Cilium | v1.20.1 | eBPF CNI, **strict kube-proxy replacement**, Gateway API, Hubble |
| kube-proxy | — | **Not installed** (`skipPhases: addon/kube-proxy`) |
| Gateway API CRDs | v1.6.1 | Six standard CRDs + experimental TLSRoute overlay, applied before Cilium |
| Ubuntu | 24.04 LTS | Base OS |
| OpenTofu | 1.8.0 | Infrastructure as Code |

Platform layer (installed by `make platform` — see [platform/README.md](platform/README.md)):

| Component | Chart | Purpose |
|-----------|-------|---------|
| EBS CSI driver | 2.63.1 | Dynamic volumes; `gp3` default StorageClass (encrypted, WaitForFirstConsumer) |
| cert-manager | v1.21.1 | Certificates; `selfsigned` ClusterIssuer, Gateway API integration |
| Shared Gateway | — | `infra/shared-gw`: HTTPS :443, `*.logistics.lab`, routes from ns `logistics` |
| CloudNativePG | 0.29.0 | PostgreSQL operator (ns `data`, operator only) |
| Strimzi | 1.1.0 | Kafka operator (ns `data`, operator only) |
| kube-prometheus-stack | 88.2.0 | Monitoring; Grafana via `kubectl port-forward` (NodePorts closed since S2-2), Alertmanager off |
| aws-iam-authenticator | v0.7.18 | IAM auth webhook (DynamicFile); daily access — admin kubeconfig is break-glass (ADR-005) |

Deployment runs in four sequential stages:

| Stage | What happens | Duration |
|-------|-------------|----------|
| 1 — Common bootstrap | containerd, kubeadm, kubelet (with `--provider-id` from IMDSv2), AWS CLI on all nodes | 3-5 min |
| 2 — Control plane init | `kubeadm init` (no kube-proxy), Gateway API CRDs, Cilium KPR, join data + kubeconfig in SSM | 5-7 min |
| 3 — Workers join | Workers poll SSM, run `kubeadm join` | 2-3 min |
| 4 — Platform | `make platform` (automatic in the CI apply workflow) | 5-10 min |

Total: 8-12 minutes of bootstrap after `make apply`, then the platform pass.

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
# edit: ssh_key_name, aws_region  (no my_ip: there is no inbound SSH)
cp tofu/envs/lab/backend.hcl.example tofu/envs/lab/backend.hcl
# edit: bucket, region, dynamodb_table

# 3. Deploy (8-12 min for bootstrap to complete)
make init
make apply

# 4. Install the platform layer (EBS CSI, cert-manager, Gateway, operators, monitoring)
make platform

# 5. Verify everything (nodes, KPR, providerID, PVC, Gateway, operators)
make smoke-test

# 6. Fetch kubeconfig from SSM and connect
make kubeconfig
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf
kubectl get nodes
```

The CI apply workflow runs the same chain automatically:
`tofu apply` → wait for bootstrap → `make platform` → `make smoke-test`.

Full walkthrough, bootstrap monitoring, and day-2 operations:
[docs/walkthrough.md](docs/walkthrough.md).

## App handoff after a recreate (contract 3b)

The app repo (`jmcj-labs/logistics-lab`) deploys as the `developer` role and
pulls its images from ECR. After every apply-from-scratch, only two GitHub
variables in that repo need refreshing — `K8S_SERVER` and `K8S_CA_DATA`
(everything else is stable). Full procedure in
[docs/troubleshooting.md](docs/troubleshooting.md) and CLUSTER.md §4. Verify
the deployed app with `make smoke-app-contract GITHUB_SHA=<sha>`.

**Pod contract** (asserted by `make smoke-app-contract`): each Deployment
carries `app.kubernetes.io/name=<service>`, its main container is named
**exactly** `<service>`, and each service exposes on the `metrics` port the
metric `logistics_service_info{service="<service>"} 1`.

## Access (IAM — ADR-005)

Daily access authenticates against the API server with IAM via
aws-iam-authenticator; the kubeadm admin kubeconfig (`make kubeconfig`,
ADR-004) is **break-glass only**. Onboarding a person = adding them to an
Identity Center group (`tofu/envs/identity` — separate, persistent stack
applied locally against the management account; see its README for the
one-time manual `jm-dev` password bootstrap).

Two separate `sso-session` blocks in `~/.aws/config` — they are two distinct
users, and sharing one session would make a `jm-dev` login replace the
platform user's:

```
sso-session: k8s-platform · profile: k8s-platform · user: existing human user · permission set: K8sPlatformBridge
sso-session: k8s-dev      · profile: k8s-dev      · user: jm-dev              · permission set: K8sDevBridge
```

```bash
make kubeconfig-admin   # exec → aws-iam-authenticator token -r …-platform-admin
make kubeconfig-dev     # exec → aws-iam-authenticator token -r …-developer (ns logistics)
aws sso login --profile k8s-platform   # when the session expires
AWS_PROFILE=k8s-platform kubectl get nodes
```

The generated kubeconfigs contain no Kubernetes credentials (only endpoint +
public CA + the exec block); `aws sso login` uses the standard AWS SSO cache
on disk. Profiles/mappings/RBAC come from `platform/access/profiles.yaml` —
profiles, not people.

---

## Cost

| Configuration | Per day (running) | Notes |
|---------------|-------------------|-------|
| Lab since S2 piece 3 | ~$7.1 | 3× On-Demand CPs (HA) + 3× Spot workers + NLB + 6 public IPv4 + 225 GiB gp3 — itemised in CLUSTER.md §FinOps |
| Pre-HA baseline (piece 2) | ~$2.1 | 1 CP + NLB — kept for comparison |
| All Spot | rejected | CP reclamation would take etcd quorum offline |

Based on t3.medium in eu-west-1. Destroy when not in use to pay only for hours used; the real
measured number after the first HA apply lives in `docs/CLUSTER.md` §FinOps. Original
breakdown: [ADR-002](docs/decisions/ADR-002-spot-workers-ondemand-cp.md).

---

## Design decisions

| ADR | Decision | Rationale |
|-----|----------|-----------|
| [ADR-001](docs/decisions/ADR-001-opentofu-vs-terraform.md) | OpenTofu over Terraform | MPL 2.0 license; Linux Foundation governance |
| [ADR-002](docs/decisions/ADR-002-spot-workers-ondemand-cp.md) | Spot workers + On-Demand control plane | 60% cost reduction ($92 → $36/month) without compromising cluster availability |
| [ADR-003](docs/decisions/ADR-003-cilium-ebpf.md) | Cilium as CNI (now strict kube-proxy replacement) | eBPF datapath; bootstrap wires `k8sServiceHost/Port` so no kube-proxy is ever installed |
| [ADR-004](docs/decisions/ADR-004-kubeconfig-ssm.md) | Kubeconfig via SSM | CI smoke test without opening port 22 to runner CIDR |
| [ADR-007](docs/decisions/ADR-007-api-endpoint-nlb.md) | HA control plane behind the NLB API endpoint | 3 CPs (stacked etcd) + stable endpoint on the existing NLB; 6443 only from the NLB's SG |
| [ADR-009](docs/decisions/ADR-009-direct-network-bootstrap.md) | Bootstrap directly into Cilium 1.20.1 + Gateway API v1.6.1 | Fresh clusters avoid a live network upgrade; the validated 4a/4b procedures become operations material |

---

## Known limitations

- **Node HA, not zonal HA** (S2 piece 3): 3 control planes with stacked etcd survive losing
  any CP, but everything lives in ONE AZ — an AZ outage kills the cluster (recovery path:
  the drilled HA restore from S3, `docs/RUNBOOK-restore-etcd-ha.md`)
- **Declared coupling**: the single NLB fronts both the application (:443) and the API
  (:6443) — a bad NLB mutation affects both (accepted for the lab, ADR-007)
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
- **K8s API public through the NLB** (ADR-004 + ADR-007): CI runners (dynamic IPs) need it
  for platform install + smoke via the SSM kubeconfig; the API is TLS + cert-authenticated,
  the CP nodes only accept 6443 from the NLB's SG, and there is no inbound SSH at all
  (node access is SSM Session Manager / Run Command — INCIDENTS #16)
- **IMDS from pods: closed by policy** (2026-08-11): hop limit 3 is still required (EBS CSI,
  Cilium tunnel — INCIDENTS #4) but a clusterwide Cilium policy denies `169.254.169.254`
  to every pod except the EBS CSI (`platform/policies/`), verified by the smoke via
  Hubble drops
- **Gateway IP is virtual** (Cilium LB-IPAM, not announced externally): external access to
  the Gateway is an internet-facing NLB (TCP/443 passthrough → deterministic
  NodePort 30443, reachable ONLY from the NLB's security group — S2 piece 2)

---

## Development

Pre-commit hooks (tofu fmt, tflint, trivy IaC scan, gitleaks), local prerequisites, and CI
enforcement: [docs/development.md](docs/development.md).

Diagnosis and fixes for common issues:
[docs/troubleshooting.md](docs/troubleshooting.md).

---

## License

MIT — see [LICENSE](LICENSE).
