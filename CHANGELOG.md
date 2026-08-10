# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

- **Platform layer** (`platform/` + `make platform`, chained into the CI apply workflow):
  EBS CSI driver (chart 2.63.1, explicit `controller.region`), default `gp3` StorageClass
  (encrypted, WaitForFirstConsumer), namespaces `infra`/`data`/`logistics` (PSA baseline on
  `logistics`), cert-manager v1.21.1 with `selfsigned` ClusterIssuer and Gateway API support,
  shared Gateway `infra/shared-gw` (cilium class, HTTPS `*.logistics.lab`, TLS via
  cert-manager), CloudNativePG 0.29.0 and Strimzi 1.1.0 operators, kube-prometheus-stack
  88.2.0 (Grafana NodePort, Alertmanager off)
- Node `spec.providerID` now set on every node (CP: post-init patch from IMDSv2; workers:
  kubelet `--provider-id` before join) — required by the EBS CSI driver
- `AmazonEBSCSIDriverPolicy` attached to control-plane and worker IAM roles
- Extended smoke test (`scripts/smoke-test.sh`): nodes Ready, no kube-proxy pods, Cilium
  `KubeProxyReplacement: True`, providerID on all nodes, dynamic gp3 PVC Bound, Gateway
  Accepted/Programmed, CNPG + Strimzi operators Ready
- `docs/INCIDENTS.md`: four findings from the 2026-08 manual platform sprint

### Changed

- **Bootstrap is now kube-proxy-free**: `kubeadm init` skips `addon/kube-proxy`; Cilium
  1.19.6 runs with `kubeProxyReplacement=true`, explicit `k8sServiceHost`/`k8sServicePort`,
  `gatewayAPI.enabled=true` and Hubble (relay + UI); Gateway API standard CRDs v1.2.1 are
  applied before the Cilium install
- kube packages unpinned to the latest 1.35.x patch (series-scoped apt repo);
  containerd.io unpinned to the latest from the Docker repo (2.3.x)
- EC2 `metadata_options`: IMDSv2 `http_put_response_hop_limit` raised 1 → 2 so
  containerized workloads can reach instance metadata
- Nightly destroy cron paused during the platform sprint (manual dispatch still available)

- `bootstrap/control-plane.yaml`: replaced previous CNI install step with pinned Cilium Helm install (`cilium/cilium` `1.19.4`) in kube-proxy compatibility mode (`kubeProxyReplacement=false`)
- Updated docs to reflect Cilium as the default CNI (`README.md`, `docs/walkthrough.md`, `docs/troubleshooting.md`, `docs/decisions/ADR-003-cilium-ebpf.md`)
- Updated module comments and development guide references to CNI/Cilium wording

## [0.1.0] - 2026-05-22

### Added

**Infrastructure (OpenTofu modules)**
- `modules/control-plane`: EC2 (t3.medium On-Demand), EIP, IAM role with SSM write access, security group; EIP-first pattern to avoid circular dependency with `templatefile()`
- `modules/worker`: EC2 (t3.medium Spot by default), IAM role with SSM read-only access, security group; `capacity_type` variable to switch spot ↔ on-demand
- `envs/lab`: VPC, public subnet, IGW, route table; orchestrates control-plane and worker modules; partial S3 backend config (account-specific values in gitignored `backend.hcl`)

**Bootstrap automation (cloud-init)**
- `bootstrap/common.yaml`: installs containerd 2.2.4, kubeadm/kubelet/kubectl 1.35.5, AWS CLI v2; handles containerd config v3 (2.x) and v2 (1.x) cgroup driver setup
- `bootstrap/control-plane.yaml`: runs `kubeadm init`, installs Cilium, stores join token + CA cert hash + kubeconfig in SSM Parameter Store (SecureString)
- `bootstrap/worker.yaml`: polls SSM until join parameters are available, runs `kubeadm join`

**GitHub Actions workflows**
- `tf-validate.yml`: runs `tofu validate` + `tofu plan` on pull requests
- `tf-destroy.yml`: manual destroy with `workflow_dispatch` confirmation gate, OIDC authentication, GitHub Variables for region and tfvars, Slack notification on completion

**Architecture Decision Records**
- ADR-001: OpenTofu over Terraform (license and community reasons)
- ADR-002: Spot workers + On-Demand control plane (cost optimisation)
- ADR-003: Cilium with kube-proxy compatibility mode (safe bootstrap without kube-proxy replacement deadlock)
- ADR-004: Kubeconfig distributed via SSM Parameter Store (CI smoke test without SSH; destroy-time cleanup provisioner)

**Security hardening**
- SSH and K8s API access restricted to `var.my_ip` by default
- IMDSv2 enforced on all EC2 instances (`http_tokens = "required"`)
- EBS root volumes encrypted
- IAM policies scoped to `/k8s/${cluster_name}/*` in SSM
- `revoke_rules_on_delete = true` on all security groups (prevents `DependencyViolation` on destroy)
- Destroy-time ENI cleanup provisioners (orphaned ENIs created by Kubernetes/CNI components at runtime)

[Unreleased]: https://github.com/jmcastellanojimenez/k8s-vanilla-lab/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jmcastellanojimenez/k8s-vanilla-lab/releases/tag/v0.1.0
