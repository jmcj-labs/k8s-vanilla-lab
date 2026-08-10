#!/usr/bin/env bash
# Smoke test for k8s-vanilla-lab: cluster + platform layer.
# Invoked by `make smoke-test` with KUBECONFIG pointing at a temp file
# fetched from SSM. Exits non-zero on the first failed check.
#
# Checks:
#   1. All nodes Ready (EXPECTED_NODES, default 3)
#   2. No kube-proxy pods (kube-proxy-free bootstrap)
#   3. Cilium reports KubeProxyReplacement: True
#   4. spec.providerID set on every node
#   5. Dynamic gp3 PVC reaches Bound (create/verify/clean)
#   6. Gateway infra/shared-gw Accepted=True and Programmed=True
#   7. CNPG and Strimzi operator pods Running

set -euo pipefail

EXPECTED_NODES="${EXPECTED_NODES:-3}"
FAIL() { echo "✗ $*" >&2; exit 1; }
OK() { echo "✓ $*"; }

echo "Cluster nodes:"
kubectl get nodes

# ── 1. Nodes Ready ────────────────────────────────────────────────────────────
TOTAL=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
NOT_READY=$(kubectl get nodes --no-headers | awk '$2 != "Ready" {n++} END {print n+0}')
[ "${TOTAL}" -eq "${EXPECTED_NODES}" ] || FAIL "Expected ${EXPECTED_NODES} nodes, found ${TOTAL}"
[ "${NOT_READY}" -eq 0 ] || FAIL "${NOT_READY} node(s) not Ready"
OK "${TOTAL}/${EXPECTED_NODES} nodes Ready"

# ── 2. No kube-proxy ──────────────────────────────────────────────────────────
KP_PODS=$(kubectl -n kube-system get pods -l k8s-app=kube-proxy --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "${KP_PODS}" -eq 0 ] || FAIL "Found ${KP_PODS} kube-proxy pod(s) — bootstrap should skip addon/kube-proxy"
OK "No kube-proxy pods"

# ── 3. Cilium kube-proxy replacement ─────────────────────────────────────────
KPR_LINE=$(kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg status 2>/dev/null | grep -i "KubeProxyReplacement" | head -1)
echo "  ${KPR_LINE}"
echo "${KPR_LINE}" | grep -q "True" || FAIL "cilium-dbg does not report KubeProxyReplacement: True"
OK "Cilium KubeProxyReplacement is True"

# ── 4. providerID on every node ──────────────────────────────────────────────
MISSING_PID=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}' \
  | awk -F'\t' '$2 == "" {print $1}')
[ -z "${MISSING_PID}" ] || FAIL "Nodes without providerID: ${MISSING_PID}"
OK "providerID set on all ${TOTAL} nodes"

# ── 5. Dynamic gp3 PVC provisioning ──────────────────────────────────────────
cleanup_pvc() {
  kubectl delete pod smoke-test-pod --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete pvc smoke-test-pvc --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup_pvc EXIT
cleanup_pvc

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smoke-test-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: gp3
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: smoke-test-pod
spec:
  restartPolicy: Never
  containers:
    - name: pause
      image: registry.k8s.io/pause:3.10
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: smoke-test-pvc
EOF

# WaitForFirstConsumer: the PVC only binds once the pod is scheduled
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/smoke-test-pvc --timeout=300s \
  || FAIL "gp3 PVC did not reach Bound within 300s"
OK "Dynamic gp3 PVC reached Bound (provisioned by ebs.csi.aws.com)"

# ── 6. Shared Gateway programmed ─────────────────────────────────────────────
kubectl -n infra wait --for=condition=Accepted gateway/shared-gw --timeout=120s \
  || FAIL "Gateway shared-gw not Accepted"
kubectl -n infra wait --for=condition=Programmed gateway/shared-gw --timeout=120s \
  || FAIL "Gateway shared-gw not Programmed"
OK "Gateway infra/shared-gw Accepted=True and Programmed=True"

# ── 7. Data operators running ────────────────────────────────────────────────
kubectl -n data wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=cloudnative-pg --timeout=120s \
  || FAIL "CloudNativePG operator pod not Ready"
OK "CloudNativePG operator Running"

kubectl -n data wait --for=condition=Ready pod \
  -l name=strimzi-cluster-operator --timeout=120s \
  || FAIL "Strimzi operator pod not Ready"
OK "Strimzi operator Running"

echo ""
echo "✓ Smoke test passed: cluster and platform layer are healthy"
