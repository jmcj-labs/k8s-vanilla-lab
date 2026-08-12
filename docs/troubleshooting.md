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

If Cilium pods are in `CrashLoopBackOff`, re-apply manually (run on the control
plane, where `hostname -i` resolves to the CP private IP — Cilium runs in strict
kube-proxy replacement mode and needs the API server address explicitly):

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.19.6 \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=$(hostname -i | awk '{print $1}') \
  --set k8sServicePort=6443 \
  --set gatewayAPI.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
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

## Network policy drops — inspecting with Hubble

Default-deny (`logistics`) and the clusterwide IMDS deny are the #1 suspects
when something degrades silently (DNS, Prometheus scrape, app→data traffic).
Hubble first, always:

```bash
# From any cilium agent (drops are seen by the agent on the node hosting
# the SOURCE pod — loop all agents if unsure):
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --verdict DROPPED --last 50

# Only drops towards IMDS (the CCNP):
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --verdict DROPPED --to-ip 169.254.169.254 --last 50

# Only drops involving a namespace:
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --verdict DROPPED --namespace logistics --last 50
```

Reading a drop line: `<src pod> -> <dst> ... Policy denied DROPPED` — the
policy that matched is on the SOURCE (egress) or DESTINATION (ingress)
endpoint. `kubectl get cnp -n <ns>` / `kubectl get ccnp` lists the policies;
the smoke's positive-first checks (DNS from logistics, control-pod egress)
tell you whether the openings themselves are broken.

## ImagePullBackOff on app images (ECR credential provider)

App images live in private ECR; the kubelet authenticates via the
`ecr-credential-provider` (no imagePullSecret). If a pod is
`ImagePullBackOff` / `ErrImagePull` on a `*.dkr.ecr.*.amazonaws.com` image:

```bash
# 1. Is the provider configured on the node the pod landed on?
kubectl get node <node> -o jsonpath='{.metadata.labels.k8s-vanilla-lab/ecr-cp}'
#    empty → the rollout never reached this node. Re-run:
#    KUBECONFIG=… bash scripts/rollout-ecr-credential-provider.sh

# 2. kubelet logs on the node show the provider being invoked / its error
#    (via a debug pod with nsenter, or make ssh-worker if you have the key):
journalctl -u kubelet | grep -i credential

# 3. Does the worker role actually allow the pull?
aws ecr get-repository-policy --repository-name <repo> --region eu-west-1
#    The four repos are in the worker role's ecr-pull policy; a NEW repo name
#    not in tofu/modules/registry (var.repositories) is NOT pullable.
```

Common causes, in order: the node missed the rollout (label absent); the
image tag does not exist (immutable tags — a re-pushed SHA is rejected at
push time, so the tag in the manifest may simply never have been pushed);
the repository name is outside the four managed ones (worker role denies it).
The credential provider caches tokens 12h — a fresh IAM permission can take
that long to matter, or restart the kubelet to force a refresh.

## App-contract operations (3b)

### Rotating projected credentials / resync

The app (developer RBAC) cannot read Secrets in `data`; `make platform`
projects the minimum into `logistics` (`logistics-pg-app`, and Kafka's
`ca.crt` only). Rotation until External Secrets = re-run the projection:

```bash
make platform   # re-runs the reentrant projection; values never printed
kubectl -n logistics get secret logistics-pg-app logistics-kafka-cluster-ca-cert
```

### Hubble verification of the metrics CNP

Prometheus (infra) is the only ADDITIONAL cross-namespace source allowed to
scrape app pods on the `metrics` port. Pods within `logistics` can also reach
`metrics` via the existing intra-namespace allow — the CNP does not isolate
metrics per service (that is Phase 1.5). To confirm the cross-namespace
denial:

```bash
# positive: the target is up
#   up{namespace="logistics", container="app"} == 1  in Prometheus
# negative: any other source is dropped
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --verdict DROPPED --to-namespace logistics --last 30
```

### Handoff after a cluster recreate

Each apply-from-scratch changes only `K8S_SERVER` and `K8S_CA_DATA`
(everything else is stable, incl. `K8S_CLUSTER_ID =
LAB_ACCOUNT_ID.REGION.CLUSTER_NAME`). Procedure:

```
destroy → apply (make smoke-test green)
→ read the new endpoint + CA:
    aws ssm get-parameter --name /k8s/<cluster>/kubeconfig --with-decryption \
      --query Parameter.Value --output text --region <region>   # server: + certificate-authority-data
→ update K8S_SERVER and K8S_CA_DATA GitHub variables in jmcj-labs/logistics-lab
→ workflow_dispatch there (rebuild → push SHA → deploy → e2e)
→ make smoke-app-contract GITHUB_SHA=<sha>
```
