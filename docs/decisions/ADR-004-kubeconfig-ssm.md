# ADR-004: Kubeconfig Distribution via SSM Parameter Store

**Status**: Accepted  
**Date**: 2026-05-22  
**Deciders**: Platform Engineering Team

---

## Context

After `tofu apply` completes and the cluster bootstraps, there is no automated way to verify that the cluster is healthy without SSHing into the control plane. A CI smoke test (e.g. `kubectl get nodes`) requires:

1. A valid kubeconfig pointing to the cluster's public IP
2. Credentials with at least `get nodes` permissions

The control plane already uses SSM Parameter Store (SecureString) to distribute the kubeadm join token and CA cert hash to worker nodes. The same mechanism can carry the kubeconfig to CI runners.

---

## Decision

After `kubeadm init` completes, the bootstrap script stores a patched kubeconfig in SSM:

- **Path**: `${ssm_parameter_path}/kubeconfig`
- **Type**: `SecureString` (encrypted via KMS default key)
- **Content**: `/etc/kubernetes/admin.conf` with `server:` rewritten to use the EIP (public IP) instead of the private IP kubeadm writes by default

The server URL patch is applied inline with `sed` before the value is pushed:

```bash
KUBECONFIG_PATCHED=$(sed \
  "s|server: https://.*:6443|server: https://${control_plane_public_ip}:6443|" \
  /etc/kubernetes/admin.conf)
aws ssm put-parameter \
  --name "${ssm_parameter_path}/kubeconfig" \
  --value "${KUBECONFIG_PATCHED}" \
  --type SecureString \
  --overwrite \
  --region ${aws_region}
```

On `tofu destroy`, a `terraform_data` destroy-time provisioner deletes all parameters under `/k8s/${cluster_name}/` (including the kubeconfig) before the IAM role is removed.

---

## Consequences

### Positive

- **No SSH required**: CI runners fetch kubeconfig via `aws ssm get-parameter --with-decryption` without opening port 22 to the runner's IP
- **Consistent with existing pattern**: Same SSM path prefix and SecureString type already used for join token and CA cert hash
- **Automatic cleanup**: The destroy-time provisioner ensures no credentials are left in SSM after infrastructure teardown
- **IAM already sufficient**: The existing `ssm:PutParameter` / `ssm:GetParameter` / `ssm:DeleteParameter` policy on `/k8s/${cluster_name}/*` covers the new parameter without changes

### Negative

- **Admin credentials in SSM**: The stored kubeconfig grants full cluster-admin access. Acceptable for a short-lived lab cluster; unacceptable for long-lived or shared environments
- **24h+ window**: Credentials persist in SSM until `tofu destroy` is run. A `--ttl` equivalent does not exist for SSM; the destroy-time provisioner is the cleanup mechanism
- **Bootstrap failure leaves nothing**: If the control plane bootstrap fails after `kubeadm init` but before Step 7.5, the kubeconfig is not stored. CI must handle a missing parameter gracefully (fall back to skip or fail explicitly)

---

## Alternatives Considered

| Option | Decision | Reason |
|--------|----------|--------|
| SSH from CI runner | Rejected | Requires opening port 22 to runner CIDR; changes security group rules dynamically |
| SSM Session Manager | Rejected | Requires SSM agent running on instance and `ssm:StartSession` — more setup, no simpler |
| Skip cluster health check in CI | Rejected | Defeats the purpose of a post-apply smoke test |
| Output kubeconfig as tofu output | Rejected | Tofu outputs are stored in state (S3); state is already encrypted, but kubeconfig as output is non-standard and confusing |

---

## References

- [SSM Parameter Store SecureString](https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-paramstore-securestring.html)
- [kubeadm init — API server SAN configuration](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/)
- ADR-002: Spot workers + On-Demand control plane
