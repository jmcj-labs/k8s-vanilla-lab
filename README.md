# k8s-vanilla-lab

**Production-quality golden path** for deploying vanilla Kubernetes clusters on AWS using kubeadm, OpenTofu, and cloud-init.

[![OpenTofu](https://img.shields.io/badge/OpenTofu-1.8.0-623CE4?logo=opentofu)](https://opentofu.org/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.35.5-326CE5?logo=kubernetes)](https://kubernetes.io/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## 📖 Table of Contents

- [For Junior Engineers: What Is This?](#-for-junior-engineers-what-is-this)
- [Architecture](#architecture)
- [Features](#features)
- [What Gets Installed](#what-gets-installed)
- [Prerequisites](#prerequisites)
  - [Local Tools](#️-local-tools)
  - [AWS Account Setup](#️-aws-account-setup)
- [Daily Usage (After Initial Setup)](#-daily-usage-after-initial-setup)
- [Quick Start (Step-by-Step)](#-quick-start-step-by-step)
- [Cost Estimate](#cost-estimate)
- [Design Decisions](#design-decisions)
- [Troubleshooting](#-troubleshooting)
- [Cleanup](#️-cleanup-destroying-the-cluster)
- [Learning Resources](#-learning-resources)
- [FAQ](#-faq)
- [AWS CLI Quick Reference](#-aws-cli-quick-reference)

---

## 📚 For Junior Engineers: What Is This?

This project teaches you **how Kubernetes really works** by building it from scratch, rather than using managed services like EKS (AWS), GKE (Google), or AKS (Azure).

**What you'll learn**:
- How Kubernetes control plane components work (API server, etcd, scheduler)
- How worker nodes join a cluster
- How container networking works (CNI plugins like Flannel)
- Infrastructure as Code with OpenTofu/Terraform
- Cloud automation with cloud-init scripts

**When to use this**:
- ✅ Learning Kubernetes internals
- ✅ Lab environment for certifications (CKA, CKAD)
- ✅ Testing Kubernetes features before implementing in production
- ❌ Production workloads (use managed Kubernetes instead)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         AWS VPC (10.0.0.0/16)                   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │         Public Subnet (10.0.1.0/24)                      │  │
│  │                                                          │  │
│  │  ┌────────────────┐          ┌──────────────────────┐    │  │
│  │  │ Control Plane  │          │   Worker Node 1      │    │  │
│  │  │  (On-Demand)   │◄────────►│     (Spot)           │    │  │
│  │  │                │          │                      │    │  │
│  │  │ • kubeadm      │          │ • kubelet            │    │  │
│  │  │ • etcd         │          │ • Flannel agent      │    │  │
│  │  │ • API server   │          └──────────────────────┘    │  │
│  │  │ • Elastic IP   │                   │                  │  │
│  │  │                │          ┌──────────────────────┐    │  │
│  │  │                │◄────────►│   Worker Node 2      │    │  │
│  │  │                │          │     (Spot)           │    │  │
│  │  └────────────────┘          │                      │    │  │
│  │         │                    │ • kubelet            │    │  │
│  │         │                    │ • Flannel agent      │    │  │
│  │         │                    └──────────────────────┘    │  │
│  │         │                                                │  │
│  │         └──► SSM Parameter Store                         │  │
│  │              (/k8s/cluster-name/join-token)              │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
│  Internet Gateway ──► Public IPs                               │
└────────────────────────────────────────────────────────────────┘
```

### 🧠 Understanding the Components

**Control Plane Node** (the "brain" of Kubernetes):
- **API Server**: RESTful API that processes `kubectl` commands
- **etcd**: Key-value database storing cluster state (like a database for Kubernetes)
- **Scheduler**: Decides which worker node should run each pod
- **Controller Manager**: Ensures desired state matches actual state (e.g., keeps 3 replicas running)
- **Elastic IP**: Fixed public IP address that doesn't change even if instance restarts

**Worker Nodes** (where your applications run):
- **kubelet**: Node agent that talks to the control plane and manages containers
- **containerd**: Container runtime that actually runs your containers
- **Flannel**: Network plugin (CNI) that enables pod-to-pod communication via VXLAN overlay

**Why Spot Instances for Workers?**
- 70% cheaper than On-Demand
- If AWS reclaims a worker, Kubernetes automatically reschedules pods to other nodes
- Control plane stays on On-Demand (more expensive but always available)

**SSM Parameter Store**:
- Secure AWS service for storing secrets
- Workers fetch the join token from here (instead of hardcoding it)
- Like a secure shared clipboard between control plane and workers

---

## Features

- **Vanilla Kubernetes**: kubeadm-bootstrapped cluster (not managed EKS)
- **Flannel CNI**: VXLAN overlay networking, installed automatically during bootstrap
- **Cost-Optimized**: ~$36/month (60% savings via spot workers)
- **Infrastructure as Code**: OpenTofu modules (Terraform-compatible)
- **Cloud-Init Automation**: Zero manual configuration
- **CI/CD Ready**: GitHub Actions with OIDC authentication
- **Security**: IMDSv2, restricted security groups, encrypted EBS

---

## What Gets Installed

| Component | Version | Purpose | Analogy |
|-----------|---------|---------|---------|
| **Kubernetes** | 1.35.5 | Container orchestration platform | The operating system for containers |
| **containerd** | 2.x | Container runtime (CRI) | The engine that runs containers (like Docker) |
| **kubeadm** | 1.35.5 | Cluster bootstrap tool | The installer for Kubernetes |
| **kubelet** | 1.35.5 | Node agent | The worker that runs on each server |
| **kubectl** | 1.35.5 | Command-line tool | Your remote control for Kubernetes |
| **Flannel** | latest | Network plugin (CNI) | The network cable between pods (VXLAN overlay) |
| **kube-proxy** | 1.35.5 | Service networking | Routes traffic to the right pod for each Service |
| **Ubuntu** | 24.04 LTS | Operating system | The base Linux system |

### 📦 What Happens During Deployment

**Stage 1: Cloud-Init Bootstrap** (8-12 minutes)
1. AWS launches EC2 instances with Ubuntu 24.04
2. `bootstrap/common.yaml` runs on ALL nodes:
   - Installs containerd 2.x (container runtime)
   - Installs kubeadm, kubelet, kubectl (Kubernetes tools)
   - Installs AWS CLI (for SSM Parameter Store access)
   - Configures kernel modules and system settings

**Stage 2: Control Plane Initialization** (~5 minutes)
1. `bootstrap/control-plane.yaml` runs on control plane:
   - Runs `kubeadm init` (creates Kubernetes cluster)
   - Installs Flannel CNI automatically (`kubectl apply`)
   - Generates bootstrap token for workers to join
   - Stores join token in AWS SSM Parameter Store
   - Configures kubectl for admin access

**Stage 3: Worker Join** (~2 minutes per worker)
1. `bootstrap/worker.yaml` runs on each worker:
   - Polls SSM Parameter Store for join token
   - Runs `kubeadm join` with the token
   - Connects to control plane via **private IP** (10.0.1.x)

**Stage 4: You download kubeconfig** (manual, 1 minute)
1. Download kubeconfig from control plane
2. Verify cluster: `kubectl get nodes` should show all nodes as `Ready`

### ⚙️ After Cluster Creation

Flannel and kube-proxy are installed automatically. No manual CNI steps needed.

Optional add-ons you can install manually:
- **Metrics Server** (for `kubectl top`) - see [addons/metrics-server/README.md](addons/metrics-server/README.md)
- **OpenCost** (for cost tracking) - see [addons/opencost/README.md](addons/opencost/README.md)

---

## Prerequisites

### 🖥️ Local Tools

You need these installed on your laptop:

| Tool | Purpose | Installation |
|------|---------|--------------|
| **OpenTofu** >= 1.8.0 | Infrastructure as Code (like Terraform) | [Guide](https://opentofu.org/docs/intro/install/) |
| **kubectl** | Kubernetes command-line tool | [Guide](https://kubernetes.io/docs/tasks/tools/) |
| **AWS CLI** | AWS command-line tool | [Guide](https://aws.amazon.com/cli/) |

**Verify installations**:
```bash
tofu version    # Should show 1.8.0 or newer
kubectl version --client
aws --version
```

### ☁️ AWS Account Setup

**What you need in AWS** (one-time setup):

#### 1. Configure AWS CLI Credentials

You need AWS credentials to deploy infrastructure. There are **two methods**:

**Method A: AWS SSO (Recommended - more secure)**

Best for: Organizations using AWS SSO/Identity Center

```bash
# Step 1: Configure SSO profile
aws configure sso

# You'll be prompted for:
# SSO session name: k8s-vanilla-lab
# SSO start URL: https://YOUR-ORG.awsapps.com/start  (get from your AWS admin)
# SSO region: us-east-1  (or your SSO region)
# SSO registration scopes: sso:account:access

# Browser will open - log in with your SSO credentials

# Then select:
# AWS account: YOUR_ACCOUNT_ID
# Role: AdministratorAccess (or role with EC2/VPC/IAM permissions)
# CLI default region: eu-west-1 (or your preferred region)
# CLI default output: json
# CLI profile name: k8s-vanilla-lab

# Step 2: Test the configuration
aws sts get-caller-identity --profile k8s-vanilla-lab

# Should show your Account ID and Role

# Step 3: Set as default profile (optional but recommended)
export AWS_PROFILE=k8s-vanilla-lab

# Add to your shell profile to persist:
echo 'export AWS_PROFILE=k8s-vanilla-lab' >> ~/.zshrc  # or ~/.bashrc
source ~/.zshrc
```

**Method B: IAM Access Keys (Simple but less secure)**

Best for: Personal AWS accounts, testing

```bash
# Step 1: Create access keys in AWS Console
# Go to: IAM → Users → Your User → Security Credentials → Create Access Key

# Step 2: Configure AWS CLI
aws configure

# You'll be prompted for:
# AWS Access Key ID: AKIAIOSFODNN7EXAMPLE
# AWS Secret Access Key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
# Default region name: eu-west-1
# Default output format: json

# Step 3: Test the configuration
aws sts get-caller-identity

# Should show your Account ID and User ARN
```

**Verify your credentials work**:
```bash
# List EC2 instances (should return empty or show existing instances)
aws ec2 describe-instances --query 'Reservations[].Instances[].InstanceId'

# If you see "Error: UnauthorizedOperation", your credentials don't have sufficient permissions
```

**Troubleshooting credentials**:
```bash
# Check current credentials
aws sts get-caller-identity

# If SSO: Renew expired session
aws sso login --profile k8s-vanilla-lab

# If Access Keys: Verify credentials file
cat ~/.aws/credentials

# List all configured profiles
aws configure list-profiles
```

#### 2. SSH Key Pair (for connecting to EC2 instances)
```bash
# Create SSH key in AWS
aws ec2 create-key-pair \
  --key-name k8s-vanilla-lab \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/k8s-vanilla-lab.pem

# Secure the key file (required by SSH)
chmod 400 ~/.ssh/k8s-vanilla-lab.pem
```

**What this does**: Creates an SSH key that lets you log into your EC2 instances.

#### 2. S3 Backend (for OpenTofu state storage)
```bash
# Create S3 bucket for state files
aws s3 mb s3://k8s-lab-tfstate-YOUR-INITIALS

# Create DynamoDB table for state locking (prevents concurrent modifications)
aws dynamodb create-table \
  --table-name k8s-vanilla-lab-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

**What this does**:
- S3 bucket stores the current state of your infrastructure (like a database)
- DynamoDB table prevents two people from modifying infrastructure at the same time

#### 3. OIDC Provider for GitHub Actions (optional - only if using CI/CD)
```bash
# Create OIDC provider (lets GitHub Actions authenticate to AWS without API keys)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

**What this does**: Allows GitHub Actions workflows to deploy to AWS securely (no hardcoded credentials).

#### 4. IAM Role for GitHub Actions (optional)

Create a file `github-actions-trust-policy.json`:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::YOUR-ACCOUNT-ID:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:YOUR-ORG/k8s-vanilla-lab:*"
      }
    }
  }]
}
```

Then create the role:
```bash
aws iam create-role \
  --role-name GitHubActionsK8sLab \
  --assume-role-policy-document file://github-actions-trust-policy.json

# Attach admin policy (WARNING: only for lab environments)
aws iam attach-role-policy \
  --role-name GitHubActionsK8sLab \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

**What this does**: Creates an IAM role that GitHub Actions can assume to deploy infrastructure.

---

## 🔄 Daily Usage (After Initial Setup)

**If you've already configured everything**, here's the quick workflow:

### Starting Your Day

```bash
# 1. Renew AWS credentials (if using SSO)
aws sso login --profile k8s-vanilla-lab

# Or verify they're still valid:
aws sts get-caller-identity

# 2. Set profile (if not in your shell profile)
export AWS_PROFILE=k8s-vanilla-lab

# 3. Navigate to project
cd path/to/k8s-vanilla-lab/tofu/envs/lab

# 4. Deploy cluster
tofu apply

# 5. Wait 8-12 minutes, then get kubeconfig
CONTROL_PLANE_IP=$(tofu output -raw control_plane_public_ip)
ssh -i ~/.ssh/k8s-vanilla-lab.pem ubuntu@${CONTROL_PLANE_IP} \
  'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/k8s-vanilla-lab.conf
sed -i.bak "s|server: https://.*:6443|server: https://${CONTROL_PLANE_IP}:6443|" ~/.kube/k8s-vanilla-lab.conf

# 6. Verify
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf
kubectl get nodes
```

### Ending Your Day (to avoid charges)

```bash
cd path/to/k8s-vanilla-lab/tofu/envs/lab
tofu destroy  # Type 'yes' to confirm
```

**Cost savings**: Destroying the cluster when not in use = $0/day (only pay for hours used)

---

## 🚀 Quick Start (Step-by-Step)

### Step 1: Clone Repository

```bash
git clone https://github.com/YOUR_ORG/k8s-vanilla-lab.git
cd k8s-vanilla-lab
```

### Step 2: Configure Variables

```bash
# Navigate to lab environment
cd tofu/envs/lab

# Copy example config
cp terraform.tfvars.example terraform.tfvars

# Edit with your values
vim terraform.tfvars  # or nano, code, etc.
```

**Edit these required variables**:
```hcl
# Your public IP (for SSH access) - get it with: curl ifconfig.me
my_ip = "203.0.113.42/32"

# SSH key name you created in prerequisites
ssh_key_name = "k8s-vanilla-lab"

# AWS region (default: eu-west-1, change if needed)
aws_region = "eu-west-1"

# Cluster name (default: k8s-vanilla-lab)
cluster_name = "k8s-vanilla-lab"

# Worker configuration
worker_count = 2                    # Number of worker nodes
worker_capacity_type = "spot"       # "spot" for 70% savings, "on-demand" for reliability
```

**Configure the backend** (copy and edit the example):
```bash
cp tofu/envs/lab/backend.hcl.example tofu/envs/lab/backend.hcl
# Edit backend.hcl: replace <YOUR_ACCOUNT_ID> with your AWS account ID
```

**What each variable means**:
- `my_ip`: Your laptop's IP (security group allows SSH only from this IP)
- `ssh_key_name`: Name of AWS SSH key to use for instance access
- `aws_region`: AWS region to deploy resources (affects cost and latency)
- `worker_capacity_type`: "spot" = cheap but can be reclaimed, "on-demand" = expensive but reliable

### Step 3: Deploy Infrastructure

```bash
# Initialize OpenTofu (downloads providers, sets up backend)
tofu init

# Preview what will be created (19 resources)
tofu plan

# Deploy everything (will ask for confirmation)
tofu apply

# Type 'yes' when prompted
```

**What `tofu apply` does**:
1. Creates VPC, subnet, Internet Gateway (networking)
2. Creates security groups (firewall rules)
3. Creates IAM roles (permissions for EC2 instances)
4. Launches 3 EC2 instances (1 control plane + 2 workers)
5. Runs cloud-init scripts to bootstrap Kubernetes

**Expected output**:
```
Apply complete! Resources: 19 added, 0 changed, 0 destroyed.

Outputs:

control_plane_public_ip = "54.220.66.70"
worker_public_ips = [
  "54.220.123.45",
  "54.220.123.46",
]
```

**⏱️ Wait 8-12 minutes** for cloud-init scripts to complete (they run in the background).

### Step 4: Check Bootstrap Progress (Optional)

You can monitor bootstrap progress by SSH-ing to nodes and checking logs:

```bash
# Get control plane IP
CONTROL_PLANE_IP=$(tofu output -raw control_plane_public_ip)

# SSH to control plane
ssh -i ~/.ssh/k8s-vanilla-lab.pem ubuntu@${CONTROL_PLANE_IP}

# Check bootstrap logs
sudo tail -f /var/log/k8s-bootstrap.log        # Common bootstrap (all nodes)
sudo tail -f /var/log/k8s-cp-bootstrap.log     # Control plane initialization

# Exit SSH
exit
```

**What to look for**:
- Common bootstrap: Should end with "Common bootstrap completed successfully"
- Control plane: Should end with "Control Plane bootstrap completed successfully"

### Step 5: Get Kubeconfig

```bash
# Extract control plane IP
CONTROL_PLANE_IP=$(tofu output -raw control_plane_public_ip)

# Download kubeconfig to your laptop
ssh -i ~/.ssh/k8s-vanilla-lab.pem ubuntu@${CONTROL_PLANE_IP} \
  'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/k8s-vanilla-lab.conf

# Fix server URL to use public IP (kubeadm writes the private IP by default)
sed -i.bak "s|server: https://.*:6443|server: https://${CONTROL_PLANE_IP}:6443|" ~/.kube/k8s-vanilla-lab.conf

# Point kubectl to this config
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf

# Verify - all nodes should already be Ready (Flannel was installed automatically)
kubectl get nodes
```

**Expected output**:
```
NAME            STATUS   ROLES           AGE   VERSION
ip-10-0-1-55    Ready    control-plane   8m    v1.35.5
ip-10-0-1-120   Ready    <none>          6m    v1.35.5
ip-10-0-1-62    Ready    <none>          6m    v1.35.5
```

**Why are they Ready immediately?** Flannel CNI and kube-proxy are installed automatically during the control plane bootstrap (Stage 2). No manual networking steps needed.

### Step 6: Verify Pod Networking

```bash
# Deploy a test pod
kubectl run test-nginx --image=nginx --port=80
kubectl get pods -w  # Watch until Running

# Should show: test-nginx   1/1     Running   0   20s

# Clean up
kubectl delete pod test-nginx
```

**Congratulations!** Your Kubernetes cluster is fully operational. 🎉

---

## Cost Estimate

| Configuration | Monthly Cost | Notes |
|---------------|--------------|-------|
| **Lab (Default)** | **~$36** | 1 On-Demand CP + 2 Spot workers |
| All On-Demand | ~$92 | Full availability (2.6× cost) |
| All Spot | ~$28 | 70% savings (risky - CP can go offline) |

**Breakdown** (t3.medium, us-east-1, 730 hours/month):
- Control Plane: $0.042/hour × 730 = $30.66
- 2× Spot Workers: $0.0126/hour × 2 × 730 = $18.40
- **Total**: $36.06/month

**To reduce costs**:
- Use smaller instances: `t3.small` (~$18/month)
- Run only when needed: `tofu destroy` when not in use

**See**: [ADR-002](docs/decisions/ADR-002-spot-workers-ondemand-cp.md) for detailed cost analysis

---

## Design Decisions

All architectural decisions documented as ADRs (Architecture Decision Records):

- **[ADR-001: OpenTofu vs Terraform](docs/decisions/ADR-001-opentofu-vs-terraform.md)**  
  Why we use OpenTofu (license, community governance)

- **[ADR-002: Spot Workers + On-Demand Control Plane](docs/decisions/ADR-002-spot-workers-ondemand-cp.md)**  
  60% cost savings while maintaining cluster availability

- **[ADR-003: Flannel vs Cilium eBPF](docs/decisions/ADR-003-cilium-ebpf.md)**  
  Why Flannel (simpler, kube-proxy compatible) over Cilium eBPF for a learning lab

---

## 🔧 Troubleshooting

### ❌ Nodes Show NotReady

**Symptom**: `kubectl get nodes` shows `STATUS: NotReady`

**Cause**: Flannel CNI hasn't finished initializing yet. Usually resolves within 1-2 minutes of nodes joining.

**Check Flannel status**:
```bash
kubectl get pods -n kube-flannel
kubectl logs -n kube-flannel -l app=flannel --tail=20
```

**If Flannel pods are crashing**, reinstall manually:
```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

---

### ❌ SSH Connection Refused

**Symptom**: `ssh: connect to host X port 22: Connection refused`

**Possible causes**:

1. **Bootstrap still running** (most common)
   - Solution: Wait 2-3 minutes after `tofu apply`, then retry

2. **Wrong security group**
   - Check: Verify `my_ip` in `terraform.tfvars` matches your current IP
   - Get your IP: `curl ifconfig.me`
   - Fix: Update `terraform.tfvars` and run `tofu apply` again

3. **Wrong SSH key**
   - Check: Verify `ssh_key_name` matches the key you created
   - Fix: Use correct key name in `terraform.tfvars`

**Debug**:
```bash
# Wait for instance to be reachable (may take 2-3 minutes)
CONTROL_PLANE_IP=$(tofu output -raw control_plane_public_ip)

# Try connecting
ssh -i ~/.ssh/k8s-vanilla-lab.pem ubuntu@${CONTROL_PLANE_IP}

# If connected, check bootstrap logs
sudo tail -100 /var/log/k8s-bootstrap.log
```

---

### ❌ Workers Not Joining Cluster

**Symptom**: Only control plane shows up in `kubectl get nodes`

**Possible causes**:

1. **Control plane bootstrap incomplete**
   - Check SSM parameters exist:
   ```bash
   aws ssm get-parameter --name /k8s/k8s-vanilla-lab/join-command --region eu-west-1
   ```
   - If "ParameterNotFound", control plane hasn't stored join token yet (wait 5 more minutes)

2. **Workers can't reach control plane**
   - Check worker logs:
   ```bash
   # Get worker IP from tofu output
   WORKER_IP=$(tofu output -json worker_public_ips | jq -r '.[0]')

   # SSH to worker
   ssh -i ~/.ssh/k8s-vanilla-lab.pem ubuntu@${WORKER_IP}

   # Check worker bootstrap logs
   sudo tail -100 /var/log/k8s-worker-bootstrap.log
   ```
   - Look for errors like "connection refused" or "timeout"

3. **Bootstrap token expired** (24h TTL)
   - If cluster is >24 hours old, generate new token:
   ```bash
   # SSH to control plane
   ssh -i ~/.ssh/k8s-vanilla-lab.pem ubuntu@${CONTROL_PLANE_IP}

   # Generate new token
   sudo kubeadm token create --ttl 24h

   # Get CA cert hash
   openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
     openssl rsa -pubin -outform der 2>/dev/null | \
     openssl dgst -sha256 -hex | sed 's/^.* //'

   # On worker, manually join (replace values):
   sudo kubeadm join 10.0.1.X:6443 \
     --token YOUR_TOKEN \
     --discovery-token-ca-cert-hash sha256:YOUR_HASH \
     --cri-socket unix:///run/containerd/containerd.sock
   ```

---

### ❌ Spot Worker Disappeared

**Symptom**: `kubectl get nodes` shows fewer workers than expected

**Cause**: AWS reclaimed spot instance (price increased or capacity needed elsewhere)

**What happens**:
- Spot instances auto-restart with `instance_interruption_behavior = "stop"`
- May take 5-10 minutes to rejoin cluster
- Kubernetes automatically reschedules pods to other nodes

**Prevention**: Set `worker_capacity_type = "on-demand"` in `terraform.tfvars` (costs 2.6× more)

**Check spot instance status**:
```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=k8s-vanilla-lab-worker-*" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,SpotInstanceRequestId]' \
  --output table
```

---

### ❌ kubectl Connection Timeout

**Symptom**: `kubectl get nodes` hangs or times out

**Possible causes**:

1. **Using private IP in kubeconfig**
   - Check server URL:
   ```bash
   grep server: ~/.kube/config
   # Should show: server: https://PUBLIC_IP:6443
   ```
   - Fix:
   ```bash
   CONTROL_PLANE_IP=$(cd tofu/envs/lab && tofu output -raw control_plane_public_ip)
   sed -i.bak "s|server: https://.*:6443|server: https://${CONTROL_PLANE_IP}:6443|" ~/.kube/config
   ```

2. **Security group blocking API server**
   - Check security group allows port 6443 from your IP
   - Verify `my_ip` in `terraform.tfvars` is correct

3. **Control plane not running**
   - Check instance status in AWS Console
   - Check kubelet: `ssh ... 'sudo systemctl status kubelet'`

---

### ❌ OpenTofu State Locked

**Symptom**: `Error: Error acquiring the state lock`

**Cause**: Previous `tofu apply` was interrupted, lock wasn't released

**Fix**:
```bash
# Get Lock ID from error message, then:
aws dynamodb delete-item \
  --table-name k8s-vanilla-lab-tflock \
  --key '{"LockID":{"S":"YOUR-BUCKET/k8s-vanilla-lab/terraform.tfstate"}}'
```

**Prevention**: Always let `tofu apply/destroy` finish naturally (don't Ctrl+C)

---

### ❌ tofu destroy Stuck / DependencyViolation

**Symptom**: `tofu destroy` hangs for 10+ minutes with errors like:
```
DependencyViolation: resource sg-xxxxxxxx has a dependent object
```

**Cause**: AWS security groups have cross-referencing rules or orphaned ENIs (created by Kubernetes/Flannel at runtime, not tracked by OpenTofu).

**Why it's now fixed**: Both security groups have `revoke_rules_on_delete = true` and `terraform_data` cleanup resources that delete orphaned ENIs on destroy. The `depends_on = [aws_internet_gateway.main]` ensures EIP associations are released before the IGW detaches.

**If you still hit it** (e.g., old state without the new resources):

```bash
# 1. Find the stuck security group
SG_ID="sg-xxxxxxxx"  # from error message

# 2. Delete orphaned ENIs attached to that SG
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=${SG_ID}" "Name=status,Values=available" \
  --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text | \
  xargs -r -n1 aws ec2 delete-network-interface --network-interface-id

# 3. Find and revoke cross-SG rules that block deletion
aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=${SG_ID}" \
  --query 'SecurityGroupRules[?ReferencedGroupInfo!=null].[SecurityGroupRuleId,ReferencedGroupInfo.GroupId]' \
  --output table

# Revoke the blocking rule (replace RULE_ID)
aws ec2 revoke-security-group-ingress \
  --group-id ${SG_ID} \
  --security-group-rule-ids sgr-XXXXXXXXXXXXXXXXX

# 4. Resume destroy
tofu destroy
```

---

### 🆘 Emergency Cleanup

If something goes wrong and you want to start fresh:

```bash
# Destroy everything
cd tofu/envs/lab
tofu destroy -auto-approve

# Wait 5 minutes, then redeploy
tofu apply
```

---

## 🗑️ Cleanup (Destroying the Cluster)

**⚠️ IMPORTANT**: This deletes ALL resources and is **irreversible**. Backup any data first.

### Option 1: Manual Destroy (Fastest)

```bash
# Navigate to lab directory
cd tofu/envs/lab

# Destroy all infrastructure
tofu destroy

# Type 'yes' when prompted
```

**What gets deleted**:
- 3 EC2 instances (control plane + 2 workers)
- Elastic IP
- VPC, subnet, Internet Gateway, route table
- Security groups
- IAM roles and instance profiles
- All Kubernetes data (pods, services, volumes)

**Time**: 2-3 minutes

### Option 2: GitHub Actions (if configured)

1. Go to **Actions** tab in GitHub
2. Select **"OpenTofu Destroy"** workflow
3. Click **"Run workflow"**
4. Type **"destroy"** in confirmation field
5. Click **"Run workflow"** button
6. Slack notification sent on completion (if configured)

---

## 🧹 Post-Cleanup

After destroying the cluster:

```bash
# Remove kubeconfig (optional)
rm ~/.kube/config

# Keep S3 backend and DynamoDB table (reuse for next deployment)
# Only delete if you're done with this project:
aws s3 rb s3://k8s-lab-tfstate-YOUR-INITIALS --force
aws dynamodb delete-table --table-name k8s-vanilla-lab-tflock
```

---

## 📚 Learning Resources

**For Junior Engineers**, these resources will help you understand the concepts:

### Kubernetes Fundamentals
- [Kubernetes Basics Tutorial](https://kubernetes.io/docs/tutorials/kubernetes-basics/) - Official hands-on tutorial
- [Kubernetes Components](https://kubernetes.io/docs/concepts/overview/components/) - What each part does
- [CKA Certification](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/) - Industry-recognized certification

### Networking
- [Kubernetes Networking Model](https://kubernetes.io/docs/concepts/services-networking/) - How pods communicate
- [Flannel Documentation](https://github.com/flannel-io/flannel#readme) - VXLAN overlay networking explained
- [CNI Specification](https://www.cni.dev/) - Container Network Interface standard

### Infrastructure as Code
- [OpenTofu Documentation](https://opentofu.org/docs/) - Complete OpenTofu guide
- [Terraform Tutorial](https://developer.hashicorp.com/terraform/tutorials) - Also applies to OpenTofu
- [Infrastructure as Code Patterns](https://www.oreilly.com/library/view/infrastructure-as-code/9781098114664/) - Book

### Cloud-Init
- [cloud-init Examples](https://cloudinit.readthedocs.io/en/latest/reference/examples.html) - Official examples
- [AWS EC2 User Data](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html) - How AWS uses cloud-init

---

## 🤝 Contributing

Contributions are welcome! Here's how:

1. **Fork the repository** on GitHub
2. **Create a feature branch**: `git checkout -b feature/my-improvement`
3. **Make changes**:
   - After `.tf` file changes, run: `tofu validate`
   - Test in your own AWS account
   - Update documentation if needed
4. **Submit a Pull Request**
   - CI will automatically run `tofu validate` and `tofu plan`
   - Address any review feedback

**Ideas for contributions**:
- Add support for different instance types
- Implement high-availability control plane (3 nodes)
- Add monitoring stack (Prometheus, Grafana)
- Support different AWS regions
- Improve bootstrap speed
- Add more comprehensive tests

---

## 📖 Additional Documentation

- **[CLAUDE.md](CLAUDE.md)**: Complete technical context for AI assistants (detailed architecture, gotchas, design patterns)
- **[VARIABLES-INTERFACE.md](VARIABLES-INTERFACE.md)**: All configurable variables explained
- **[ADR-001](docs/decisions/ADR-001-opentofu-vs-terraform.md)**: Why OpenTofu instead of Terraform
- **[ADR-002](docs/decisions/ADR-002-spot-workers-ondemand-cp.md)**: Cost analysis (spot vs on-demand)
- **[ADR-003](docs/decisions/ADR-003-cilium-ebpf.md)**: Why Cilium eBPF over kube-proxy

---

## 📝 License

MIT License - see [LICENSE](LICENSE) for details.

---

## 🌐 External References

- **OpenTofu**: https://opentofu.org/
- **Kubernetes**: https://kubernetes.io/
- **Flannel**: https://github.com/flannel-io/flannel
- **kubeadm**: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/
- **containerd**: https://containerd.io/
- **cloud-init**: https://cloudinit.readthedocs.io/

---

## 🙏 Acknowledgments

Built with ❤️ for learning Kubernetes internals

**Tech Stack**: OpenTofu • Kubernetes 1.35 • Flannel CNI • containerd 2.x • AWS EC2 • cloud-init • GitHub Actions

**Project Goals**:
- ✅ Production-quality patterns for learning
- ✅ Cost-optimized for lab use (~$36/month)
- ✅ Well-documented for junior engineers
- ✅ Modern Kubernetes stack (v1.35, containerd 2.x, Flannel)
- ✅ Infrastructure as Code best practices

---

## ❓ FAQ

**Q: Why not use EKS instead?**
A: EKS is great for production, but this project is for **learning Kubernetes internals**. You won't understand how API server, etcd, or kubelet work if you use managed Kubernetes.

**Q: Can I use this in production?**
A: No. This is a learning lab. For production:
- Use managed Kubernetes (EKS, GKE, AKS)
- Implement high availability (3+ control planes)
- Use on-demand instances (not spot)
- Add monitoring, backups, disaster recovery
- Implement security hardening (network policies, PSS, OPA)

**Q: Why OpenTofu instead of Terraform?**
A: License and community governance. See [ADR-001](docs/decisions/ADR-001-opentofu-vs-terraform.md) for full reasoning.

**Q: Why Flannel instead of Cilium?**
A: Flannel is simpler and easier to understand for learning. It uses VXLAN overlay networking which is a foundational concept in Kubernetes. Cilium (eBPF) is more powerful but adds complexity. See [ADR-003](docs/decisions/ADR-003-cilium-ebpf.md) for the original Cilium rationale.

**Q: How do I upgrade Kubernetes?**
A: Update `kubernetes_version` in `tofu/envs/lab/main.tf` and bootstrap scripts. See [CLAUDE.md](CLAUDE.md) for version update procedures.

**Q: What if I want more/fewer workers?**
A: Change `worker_count` in `terraform.tfvars`, then run `tofu apply`.

**Q: Can I use different instance types?**
A: Yes! Change `control_plane_instance_type` and `worker_instance_type` in `terraform.tfvars`. Recommended: t3.medium or larger.

**Q: Why does bootstrap take 8-12 minutes?**
A: Installing containerd, Kubernetes packages, and running `kubeadm init` takes time. This is normal for vanilla Kubernetes.

**Q: How do I renew my AWS SSO session?**
A: Run `aws sso login --profile k8s-vanilla-lab`. SSO sessions expire after a few hours.

**Q: Can I use multiple AWS profiles?**
A: Yes! Use `export AWS_PROFILE=profile-name` to switch between profiles. Or specify per-command: `aws ec2 describe-instances --profile other-profile`

**Q: How do I check my current AWS credentials?**
A: Run `aws sts get-caller-identity`. Shows Account ID, User/Role ARN, and confirms credentials are valid.

---

## 🔐 AWS CLI Quick Reference

**Common commands for managing credentials**:

```bash
# Check current credentials
aws sts get-caller-identity

# SSO: Login/renew session
aws sso login --profile k8s-vanilla-lab

# SSO: Logout
aws sso logout --profile k8s-vanilla-lab

# List all configured profiles
aws configure list-profiles

# Show current profile configuration
aws configure list

# Switch profile for current shell session
export AWS_PROFILE=k8s-vanilla-lab

# Unset profile (use default)
unset AWS_PROFILE

# Check if credentials are expired
aws sts get-caller-identity && echo "✓ Valid" || echo "✗ Expired - run: aws sso login"
```

**Checking cluster status from CLI**:

```bash
# List EC2 instances
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=k8s-vanilla-lab-*" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# Check if cluster is running
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=k8s-vanilla-lab-control-plane" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PublicIpAddress' \
  --output text

# List SSM parameters (join tokens)
aws ssm describe-parameters \
  --parameter-filters "Key=Name,Values=/k8s/k8s-vanilla-lab" \
  --query 'Parameters[].[Name,LastModifiedDate]' \
  --output table

# Get monthly AWS cost estimate
aws ce get-cost-and-usage \
  --time-period Start=$(date -u -d '30 days ago' +%Y-%m-%d),End=$(date -u +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --group-by Type=SERVICE
```

---

**Ready to start?** Go to [Prerequisites](#prerequisites) and begin your Kubernetes journey! 🚀
