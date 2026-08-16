# OpenTofu Templatefile Escaping Rules

## Critical Rule for Shell Variables in Templates

**Problem**: OpenTofu templatefile() uses `${}` syntax for its own variables. Shell scripts in the same file also use `${}`, causing conflicts.

**Solution**: Shell variables MUST use `$${}` so OpenTofu passes them through as `${}` to the shell at runtime.

---

## Variable Types in cloud-init Templates

### 1. OpenTofu Template Variables (Single $)
**Syntax**: `${variable_name}`
**Usage**: Variables passed via templatefile() function
**Example**:
```yaml
clusterName: ${cluster_name}
region: ${aws_region}
apiServer: ${api_endpoint_dns}:6443
```

**These are replaced by OpenTofu BEFORE the file is passed to cloud-init.**

---

### 2. Shell Variables (Double $$)
**Syntax**: `$${SHELL_VAR}`
**Usage**: Variables set and used within the shell script
**Example**:
```bash
JOIN_TOKEN=$$(kubeadm token create --ttl 24h)
CA_CERT_HASH=$$(openssl x509 -pubkey ...)
PRIVATE_IP=$$(hostname -i | awk '{print $$1}')
API_ENDPOINT="$${PRIVATE_IP}:6443"

aws ssm put-parameter \
  --name "${ssm_parameter_path}/join-command" \
  --value "$${JOIN_COMMAND}" \
  --region ${aws_region}
```

**OpenTofu converts `$$` → `$` before cloud-init receives it.**

---

### 3. Command Substitutions (No Escaping Needed)
**Syntax**: `$(command)` or `` `command` ``
**Usage**: Shell command execution
**Example**:
```bash
certSANs:
  - $(hostname -i)      # No escaping - this is command substitution
  - $(hostname -f)
```

**These are NOT variables, so no escaping needed. They execute at runtime.**

---

### 4. Special Case: awk $1 Inside Command Substitution
**Syntax**: `$$1` inside `$()`
**Example**:
```bash
PRIVATE_IP=$$(hostname -i | awk '{print $$1}')
```

**Why**: The outer `$$` escapes the shell variable assignment. The inner `$$1` escapes awk's field reference.

---

## Fixed Variables in control-plane.yaml

| Original (WRONG) | Fixed (CORRECT) | Context |
|------------------|-----------------|---------|
| `${TIMEOUT}` | `$${TIMEOUT}` | Shell variable in loop |
| `${ELAPSED}` | `$${ELAPSED}` | Shell variable in loop |
| `${INTERVAL}` | `$${INTERVAL}` | Shell variable in loop |
| `${JOIN_TOKEN}` | `$${JOIN_TOKEN}` | kubeadm token output |
| `${CA_CERT_HASH}` | `$${CA_CERT_HASH}` | Certificate hash |
| `${PRIVATE_IP}` | `$${PRIVATE_IP}` | Private IP from hostname |
| `${API_ENDPOINT}` | `$${API_ENDPOINT}` | Constructed endpoint |
| `${JOIN_COMMAND}` | `$${JOIN_COMMAND}` | Full join command |
| `$(hostname -i)` | `$(hostname -i)` | NO CHANGE - command sub |
| `{print $1}` | `{print $$1}` | awk field in command sub |

---

## Validation

After applying these rules, run:
```bash
cd tofu/envs/lab
terraform init -backend=false
terraform validate
```

Expected output: `Success! The configuration is valid.`

---

## Summary

✅ **OpenTofu variables**: `${variable}` (single $)
✅ **Shell variables**: `$${VARIABLE}` (double $$)
✅ **Command substitutions**: `$(command)` (no escaping)
✅ **awk fields in commands**: `$$1` (double $$)

**Remember**: If it's set/used in the shell script, it needs `$$`.
