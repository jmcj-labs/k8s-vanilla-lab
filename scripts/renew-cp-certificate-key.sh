#!/usr/bin/env bash
# Renew the kubeadm certificate-key (control-plane join material).
#
# WHY: `kubeadm init phase upload-certs` encrypts the CP certificates into
# the kubeadm-certs Secret with a key whose TTL is 2h — after that, BOTH
# the Secret and the key are useless. A replacement CP arriving later than
# 2h after the last upload cannot join until a SURVIVING CP re-uploads the
# certs and publishes the fresh key. Keeping the old key in SSM would NOT
# help: the Secret itself is gone; re-upload is the only cure (ADR-007,
# docs/RUNBOOK-renew-cp-certkey.md).
#
# HOW: privileged nsenter Job pinned to a Ready control plane (the house's
# no-SSH pattern). The key NEVER leaves the node in logs: the Job itself
# publishes it to SSM cp/certificate-key using the CP instance role (which
# owns /k8s/<cluster>/* — the cp/ path is CP-role-only by design). The
# waiting replacement CP re-fetches the key on every join retry
# (bootstrap/control-plane-join.yaml step 5).
#
# Requires: kubectl (admin) against the live cluster. No AWS credentials
# needed locally — the SSM write happens on the node.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
log()  { echo "[$(date -u +'%H:%M:%SZ')] $*"; }
FAIL() { echo "✗ $*" >&2; exit 1; }

command -v kubectl >/dev/null || FAIL "kubectl not found"

# A READY control plane (arg 1 overrides — e.g. to avoid a node under drill)
CP_NODE="${1:-}"
if [ -z "${CP_NODE}" ]; then
  CP_NODE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane \
    -o json | python3 -c '
import json,sys
for n in json.load(sys.stdin)["items"]:
    if any(c["type"]=="Ready" and c["status"]=="True" for c in n["status"]["conditions"]):
        print(n["metadata"]["name"]); break')
fi
[ -n "${CP_NODE}" ] || FAIL "no Ready control-plane node found"
log "=== certificate-key renewal on ${CP_NODE} ==="

kubectl -n kube-system delete job renew-cp-certkey --ignore-not-found >/dev/null
kubectl -n kube-system apply -f - <<JOB
apiVersion: batch/v1
kind: Job
metadata:
  name: renew-cp-certkey
  labels: {app.kubernetes.io/part-of: k8s-vanilla-lab-access}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 900
  template:
    spec:
      restartPolicy: Never
      hostPID: true
      hostNetwork: true
      nodeName: ${CP_NODE}
      tolerations: [{operator: Exists}]
      containers:
        - name: renew
          image: public.ecr.aws/docker/library/busybox:1.36
          securityContext: {privileged: true}
          command: ["nsenter", "--target", "1", "--mount", "--uts", "--ipc", "--net", "--pid", "--", "bash", "-euo", "pipefail", "-c"]
          args:
            - |
              KEY=\$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
              echo "\$KEY" | grep -Eq '^[0-9a-f]{64}\$' || { echo "invalid key captured" >&2; exit 1; }
              aws ssm put-parameter \
                --name "/k8s/${CLUSTER_NAME}/cp/certificate-key" \
                --value "\$KEY" \
                --type SecureString \
                --overwrite \
                --region "${AWS_REGION}" >/dev/null
              echo "certificate-key renewed and published to SSM (never logged); kubeadm-certs TTL restarted (2h)"
JOB

kubectl -n kube-system wait --for=condition=complete job/renew-cp-certkey --timeout=180s >/dev/null \
  || { kubectl -n kube-system logs job/renew-cp-certkey --tail=5 || true; FAIL "renewal job did not complete"; }
kubectl -n kube-system logs job/renew-cp-certkey --tail=1
kubectl -n kube-system delete job renew-cp-certkey --ignore-not-found >/dev/null
log "✓ done — a waiting replacement CP will pick the fresh key on its next retry (≤120s)"
