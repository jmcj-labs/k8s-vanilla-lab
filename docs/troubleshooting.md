# Troubleshooting

Diagnosis and fixes for common issues. Unless noted otherwise, `tofu output` commands should be
run from `tofu/envs/lab/`.

---

## Nodes show NotReady

**Symptom**: `kubectl get nodes` shows `NotReady`

**Cause**: Cilium CNI hasn't finished initializing. Usually resolves 1-2 minutes after nodes join.

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/part-of=cilium
kubectl logs -n kube-system -l app.kubernetes.io/part-of=cilium --tail=20
```

If Cilium pods are in `CrashLoopBackOff`, re-apply manually:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.19.4 \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=false
```

---

## SSH connection refused

**Symptom**: `ssh: connect to host X port 22: Connection refused`

**Most likely cause**: Bootstrap is still running. Wait 2-3 minutes after `make apply`, then retry.

Other causes:

| Cause | Fix |
|-------|-----|
| `my_ip` doesn't match your current IP | `curl ifconfig.me` → update `terraform.tfvars` → `make apply` |
| Wrong SSH key | Verify `ssh_key_name` in `terraform.tfvars` matches the key pair in AWS |

```bash
make ssh-cp     # control plane
make ssh-worker # first worker
```

---

## Workers not joining the cluster

**Symptom**: Only the control plane shows in `kubectl get nodes`

**Step 1: Check if SSM has the join data**

```bash
aws ssm get-parameter \
  --name /k8s/k8s-vanilla-lab/join-command \
  --region eu-west-1 \
  --query Parameter.Value \
  --output text
```

`ParameterNotFound` means the control plane bootstrap hasn't completed yet. Check Stage 2 logs:

```bash
make ssh-cp
sudo tail -100 /var/log/k8s-cp-bootstrap.log
```

**Step 2: Check worker logs**

```bash
make ssh-worker
sudo tail -100 /var/log/k8s-worker-bootstrap.log
```

Look for `connection refused` or timeout errors pointing at the control plane private IP.

**Step 3: Token expired (24h TTL)**

Bootstrap tokens expire after 24 hours. If a worker needs to rejoin after that window:

```bash
# On the control plane
make ssh-cp

# Generate a new token
sudo kubeadm token create --ttl 24h

# Get the CA cert hash
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
  openssl rsa -pubin -outform der 2>/dev/null | \
  openssl dgst -sha256 -hex | sed 's/^.* //'
```

Then on the worker:

```bash
make ssh-worker

sudo kubeadm join 10.0.1.X:6443 \
  --token YOUR_TOKEN \
  --discovery-token-ca-cert-hash sha256:YOUR_HASH \
  --cri-socket unix:///run/containerd/containerd.sock
```

---

## Spot worker disappeared

**Symptom**: `kubectl get nodes` shows fewer workers than expected

**Cause**: AWS reclaimed the spot instance.

Spot instances are configured with `instance_interruption_behavior = "stop"`, so the instance
auto-restarts. Workers typically rejoin within 5-10 minutes. Kubernetes reschedules pods
automatically during the gap.

Check spot instance state:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=k8s-vanilla-lab-worker-*" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,SpotInstanceRequestId]' \
  --output table
```

To prevent interruptions: set `worker_capacity_type = "on-demand"` in `terraform.tfvars` and
run `make apply`.

---

## kubectl connection timeout

**Symptom**: `kubectl get nodes` hangs or times out

**Check the server URL in the kubeconfig**:

```bash
grep server: ~/.kube/k8s-vanilla-lab.conf
# Should show: server: https://PUBLIC_IP:6443
```

If it shows a private IP (`10.x.x.x`), re-fetch:

```bash
make kubeconfig
```

Other causes:

| Cause | Fix |
|-------|-----|
| Port 6443 blocked by security group | Verify `my_ip` in `terraform.tfvars` covers your current IP; `make apply` to update |
| Control plane not running | Check instance state in AWS console; `make ssh-cp` then `sudo systemctl status kubelet` |

---

## OpenTofu state locked

**Symptom**: `Error: Error acquiring the state lock`

**Cause**: A previous `tofu apply` or `tofu destroy` was interrupted before releasing the lock.

Get the Lock ID from the error message, then:

```bash
aws dynamodb delete-item \
  --table-name k8s-vanilla-lab-tflock \
  --key '{"LockID":{"S":"YOUR-BUCKET/k8s-vanilla-lab/terraform.tfstate"}}'
```

Only force-unlock if you are certain no other apply or destroy is running against this state.

---

## `make destroy` stuck / DependencyViolation

**Symptom**: `make destroy` hangs for 10+ minutes with:

```
DependencyViolation: resource sg-xxxxxxxx has a dependent object
```

**Cause**: Kubernetes and CNI components create ENIs (network interfaces) at runtime that OpenTofu
doesn't track. These orphaned ENIs hold a reference to the security group, blocking deletion.

Both security groups have `revoke_rules_on_delete = true` and a `terraform_data` destroy-time
provisioner that deletes orphaned ENIs automatically. If you hit this with an older state that
predates those resources:

```bash
# 1. Identify the stuck security group from the error message
SG_ID="sg-xxxxxxxx"

# 2. Delete orphaned ENIs attached to this SG
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=${SG_ID}" "Name=status,Values=available" \
  --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text | \
  xargs -r -n1 aws ec2 delete-network-interface --network-interface-id

# 3. Find cross-SG rules that block deletion
aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=${SG_ID}" \
  --query 'SecurityGroupRules[?ReferencedGroupInfo!=null].[SecurityGroupRuleId,ReferencedGroupInfo.GroupId]' \
  --output table

# 4. Revoke the blocking rule
aws ec2 revoke-security-group-ingress \
  --group-id ${SG_ID} \
  --security-group-rule-ids sgr-XXXXXXXXXXXXXXXXX

# 5. Resume
make destroy
```

---

## Emergency cleanup

If state is corrupted or `make destroy` fails repeatedly:

```bash
# Remove a specific resource from state without deleting the AWS resource
cd tofu/envs/lab
tofu state rm <resource_address>

# Terminate instances directly by project tag
aws ec2 terminate-instances \
  --instance-ids $(aws ec2 describe-instances \
    --filters "Name=tag:project,Values=k8s-vanilla-lab" \
              "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text)

# Delete the state file (last resort — loses all state tracking)
aws s3 rm s3://YOUR-BUCKET/k8s-vanilla-lab/terraform.tfstate
```

After manual cleanup, `make destroy` will error on already-deleted resources. Use
`tofu state rm` to remove each orphaned resource from state before re-deploying.
