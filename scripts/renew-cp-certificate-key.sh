#!/usr/bin/env bash
# Renew the FULL control-plane join material: certificate-key (2h) AND
# bootstrap token (24h). A CP join needs BOTH — renewing one alone leaves
# the replacement stuck on the other, which is the whole failure this
# ceremony exists to prevent.
#
# WHY: `kubeadm init phase upload-certs` encrypts the CP certificates into
# the kubeadm-certs Secret with a key whose TTL is 2h — after that, BOTH
# the Secret and the key are useless. A replacement CP arriving later than
# 2h after the last upload cannot join until a SURVIVING CP re-uploads the
# certs and publishes the fresh key. Keeping the old key in SSM would NOT
# help: the Secret itself is gone; re-upload is the only cure. The join
# token in `join-command` expires at 24h with the same effect (ADR-007,
# docs/RUNBOOK-renew-cp-certkey.md).
#
# NOTE: the CI apply workflow already mints a fresh token before every
# apply on a live cluster ("Preflight join token"), so a replacement driven
# by Apply gets its token automatically — this script covers the manual
# path and makes the precondition explicit instead of implicit.
#
# HOW: privileged nsenter Job pinned to a Ready control plane (the house's
# no-SSH pattern). The key NEVER leaves the node in logs: the Job itself
# publishes it to SSM cp/certificate-key using the CP instance role (which
# owns /k8s/<cluster>/* — the cp/ path is excluded from the worker role). The
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

              # The 24h bootstrap token is the OTHER half of the join
              # material: rebuild join-command preserving the endpoint and
              # CA hash already published (kubeadm token create prints only
              # the token).
              OLD_JOIN=\$(aws ssm get-parameter --name "/k8s/${CLUSTER_NAME}/join-command" \
                --with-decryption --query Parameter.Value --output text --region "${AWS_REGION}")
              ENDPOINT=\$(echo "\$OLD_JOIN" | awk '{print \$3}')
              CA_HASH=\$(echo "\$OLD_JOIN" | grep -o 'sha256:[a-f0-9]*')
              [ -n "\$ENDPOINT" ] && [ -n "\$CA_HASH" ] || { echo "could not parse join-command" >&2; exit 1; }
              TOKEN=\$(kubeadm token create --ttl 24h)
              echo "\$TOKEN" | grep -Eq '^[a-z0-9]{6}\.[a-z0-9]{16}\$' || { echo "invalid token" >&2; exit 1; }
              aws ssm put-parameter \
                --name "/k8s/${CLUSTER_NAME}/join-command" \
                --value "kubeadm join \$ENDPOINT --token \$TOKEN --discovery-token-ca-cert-hash \$CA_HASH" \
                --type SecureString \
                --overwrite \
                --region "${AWS_REGION}" >/dev/null
              echo "join material renewed (never logged): certificate-key TTL 2h + bootstrap token TTL 24h; endpoint \$ENDPOINT preserved"
JOB

kubectl -n kube-system wait --for=condition=complete job/renew-cp-certkey --timeout=180s >/dev/null \
  || { kubectl -n kube-system logs job/renew-cp-certkey --tail=5 || true; FAIL "renewal job did not complete"; }
kubectl -n kube-system logs job/renew-cp-certkey --tail=1
kubectl -n kube-system delete job renew-cp-certkey --ignore-not-found >/dev/null
log "✓ done — a waiting replacement CP will pick the fresh key on its next retry (≤120s)"
