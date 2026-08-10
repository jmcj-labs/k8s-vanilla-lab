# Platform layer

Everything the cluster offers to application teams beyond vanilla Kubernetes:
storage, certificates, ingress (Gateway API), data operators and monitoring.
Installed in one ordered, idempotent pass by [`install.sh`](install.sh).

## What gets installed (in order)

| # | Component | Namespace | Chart (version) | Key settings |
|---|-----------|-----------|-----------------|--------------|
| 1 | Namespaces + StorageClass | — | manifests | `logistics` labeled PSA `enforce=baseline`; `gp3` default SC (`ebs.csi.aws.com`, WaitForFirstConsumer, encrypted) |
| 2 | EBS CSI driver | `kube-system` | `aws-ebs-csi-driver` 2.63.1 | `controller.region` set explicitly (IMDS unreachable from pod network — see `docs/INCIDENTS.md` #4) |
| 3 | cert-manager | `infra` | `cert-manager` v1.21.1 | `crds.enabled=true`, `--enable-gateway-api`; plus `ClusterIssuer/selfsigned` |
| 4 | Shared Gateway | `infra` | manifest | `shared-gw`: class `cilium`, HTTPS :443, `*.logistics.lab`, TLS Terminate with cert-manager cert, routes only from ns `logistics`. A Cilium LB-IPAM pool (`lb-ipam-pool.yaml`, virtual CIDR `172.20.255.0/24`) gives its LoadBalancer Service an address so the Gateway reaches `Programmed=True` — external access is via NodePort until the Sprint 2 ingress decision (NLB) |
| 5 | CloudNativePG | `data` | `cloudnative-pg` 0.29.0 | operator only — PG clusters are app-owned |
| 6 | Strimzi | `data` | `strimzi-kafka-operator` 1.1.0 | operator only — Kafka clusters are app-owned |
| 7 | kube-prometheus-stack | `infra` | `kube-prometheus-stack` 88.2.0 | `grafana.service.type=NodePort`, `alertmanager.enabled=false` |

Prerequisites provided by the bootstrap layer (cloud-init):

- Cilium in kube-proxy replacement mode with `gatewayAPI.enabled=true`
  (creates the `cilium` GatewayClass).
- Gateway API standard CRDs v1.2.1.
- Node `spec.providerID` set on every node (EBS CSI requirement).
- IMDSv2 hop limit 3 + `AmazonEBSCSIDriverPolicy` on node roles (OpenTofu).

## How to run

```bash
make platform          # fetches kubeconfig from SSM into a temp file and runs install.sh
```

Or directly, with your own kubeconfig:

```bash
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf   # make kubeconfig
AWS_REGION=eu-west-1 bash platform/install.sh
```

The script is idempotent (`helm upgrade --install` + `kubectl apply`) — re-run
it freely after changing a version or a value.

## Execution model (why not from the control-plane cloud-init?)

`install.sh` runs **against the kubeconfig** (locally or from the CI apply
workflow, which chains apply → platform → smoke-test), not from the
control-plane bootstrap. Deliberate trade-off:

- **cloud-init is first-boot only**: a platform change embedded in user_data
  could never be rolled out to an existing cluster; `make platform` re-applies
  in seconds.
- **user_data size**: EC2 caps user_data at 16 KB; the platform layer
  (script + manifests) does not fit alongside the bootstrap scripts, and
  fetching the repo from the node would add a runtime dependency on the git
  remote from inside the instance.
- **Same automation guarantee**: the CI apply workflow runs `make platform`
  automatically after `make apply`, so a full cluster still comes up with no
  manual intervention.

## Full flow

```
make apply → (8–12 min bootstrap) → make platform → make smoke-test
```
