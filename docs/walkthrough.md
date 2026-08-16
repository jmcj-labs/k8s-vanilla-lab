# Deployment Walkthrough

Full step-by-step guide for first deployment. Assumes [AWS one-time setup](bootstrap.md) is complete.

---

## 1. Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| OpenTofu | >= 1.8.0 | [opentofu.org/docs/intro/install](https://opentofu.org/docs/intro/install/) |
| kubectl | any | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| AWS CLI | v2 | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |

AWS account setup (S3 state bucket, DynamoDB lock table, OIDC provider, IAM role for CI): see [docs/bootstrap.md](bootstrap.md).

---

## 2. Clone and configure

```bash
git clone https://github.com/jmcj-labs/k8s-vanilla-lab.git
cd k8s-vanilla-lab
```

**terraform.tfvars** — copy the example and set your values:

```bash
cp tofu/envs/lab/terraform.tfvars.example tofu/envs/lab/terraform.tfvars
```

Required fields:

```hcl
ssh_key_name = "k8s-vanilla-lab"   # AWS key pair name
aws_region   = "eu-west-1"
cluster_name = "k8s-vanilla-lab"
```

Optional fields and their defaults:

```hcl
worker_count         = 2        # number of worker nodes
worker_capacity_type = "spot"   # "spot" or "on-demand"
```

**backend.hcl** — copy and fill in your backend coordinates:

```bash
cp tofu/envs/lab/backend.hcl.example tofu/envs/lab/backend.hcl
# edit: bucket, region, dynamodb_table
```

---

## 3. Initialize and apply

```bash
# Download providers and connect to the S3 backend
make init

# Preview: should show ~19 resources to add
make plan   # optional but recommended on first run

# Deploy
make apply
```

`make apply` creates the VPC, subnets, Internet Gateway, security groups, IAM roles, and three EC2
instances in one pass. Cloud-init scripts start immediately in the background.

Expected output:

```
Apply complete! Resources: 19 added, 0 changed, 0 destroyed.

Outputs:

control_plane_public_ips = [
  "54.220.66.70",
  "54.220.66.71",
  "54.220.66.72",
]
nlb_dns_name = "k8s-vanilla-lab-gw-nlb-xxxxxxxx.elb.eu-west-1.amazonaws.com"
worker_public_ips = [
  "54.220.123.45",
  "54.220.123.46",
]
```

**Wait 8-12 minutes** before proceeding. Bootstrap runs in three stages:

| Stage | Script | Duration |
|-------|--------|----------|
| 1 — Common (all nodes) | `bootstrap/common.yaml` | 3-5 min |
| 2 — Control plane init | `bootstrap/control-plane.yaml` | 5-7 min |
| 3 — Workers join | `bootstrap/worker.yaml` | 2-3 min |

---

## 4. Monitor bootstrap progress (optional)

```bash
# SSH into the control plane
make ssm-cp

# Inside the instance:
sudo tail -f /var/log/k8s-bootstrap.log       # Stage 1 — containerd, kubeadm install
sudo tail -f /var/log/k8s-cp-bootstrap.log    # Stage 2 — kubeadm init, Cilium, SSM store
```

Stage 2 is complete when the log ends with:

```
Control Plane bootstrap completed successfully
```

For workers:

```bash
make ssm-worker   # opens a session on worker node 1

sudo tail -f /var/log/k8s-bootstrap.log          # Stage 1
sudo tail -f /var/log/k8s-worker-bootstrap.log   # Stage 3 — SSM poll, kubeadm join
```

---

## 5. Get kubeconfig

`make kubeconfig` fetches the kubeconfig from SSM Parameter Store, where the control plane stored it
after `kubeadm init`. The value has the `server:` URL already patched to the Elastic IP
(see [ADR-004](decisions/ADR-004-kubeconfig-ssm.md)).

```bash
make kubeconfig
# ✓ Kubeconfig saved to ~/.kube/k8s-vanilla-lab.conf
#
#   export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf

export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf
```

---

## 6. Verify the cluster

```bash
kubectl get nodes
```

Expected output (Cilium is installed automatically during Stage 2, so all nodes come up `Ready`):

```
NAME            STATUS   ROLES           AGE   VERSION
ip-10-0-1-55    Ready    control-plane   8m    v1.35.5
ip-10-0-1-120   Ready    <none>          6m    v1.35.5
ip-10-0-1-62    Ready    <none>          6m    v1.35.5
```

If nodes show `NotReady`, Cilium is still initializing — check `kubectl get pods -n kube-system -l app.kubernetes.io/part-of=cilium`.
Usually resolves within 1-2 minutes. See [troubleshooting.md](troubleshooting.md) if it persists.

---

## 7. Verify pod networking

```bash
kubectl run test-nginx --image=nginx --port=80
kubectl get pods -w   # wait until Running

# Expected:
# test-nginx   1/1     Running   0   20s

kubectl delete pod test-nginx
```

---

## 8. Day-2 operations

| Task | Command |
|------|---------|
| Re-apply after config changes | `make apply` |
| Verify cluster health | `make smoke-test` |
| Shell on a control plane | `make ssm-cp` (SSM Session Manager) |
| Shell on the first worker | `make ssm-worker` |
| Refresh kubeconfig | `make kubeconfig` |

`make apply` is idempotent — safe to re-run after variable changes without tearing down the cluster.

`make smoke-test` fetches the kubeconfig from SSM in a temporary file (not persisted to disk),
runs `kubectl get nodes`, and exits non-zero if any node is not `Ready`. Used by the CI apply
workflow as a post-deploy health check.

---

## 9. Teardown

**Manual**:

```bash
make destroy
```

Deletes all AWS resources: EC2 instances, VPC, subnets, Internet Gateway, security groups, IAM
roles, Elastic IP, SSM parameters. The S3 backend bucket and DynamoDB lock table are **not**
deleted — reuse them for future deployments.

**Via GitHub Actions**:

1. Go to **Actions → OpenTofu Destroy**
2. Click **Run workflow**
3. Enter `destroy` in the confirmation field
4. Slack notification sent on completion if `SLACK_WEBHOOK_URL` is configured

The workflow also runs on a nightly cron (`0 22 * * *`) to prevent overnight charges.
