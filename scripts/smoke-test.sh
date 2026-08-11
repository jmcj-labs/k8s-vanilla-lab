#!/usr/bin/env bash
# Smoke test for k8s-vanilla-lab: cluster + platform layer.
# Invoked by `make smoke-test` with KUBECONFIG pointing at a temp file
# fetched from SSM. Exits non-zero on the first failed check.
#
# Checks:
#   1. All nodes Ready (EXPECTED_NODES, default 4)
#   2. No kube-proxy pods (kube-proxy-free bootstrap)
#   3. Cilium reports KubeProxyReplacement: True
#   4. spec.providerID set on every node
#   5. Dynamic gp3 PVC reaches Bound (create/verify/clean)
#   6. Gateway infra/shared-gw Accepted=True and Programmed=True
#   7. CNPG and Strimzi operator pods Running

set -euo pipefail

EXPECTED_NODES="${EXPECTED_NODES:-4}"
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
# Bound proves provisioning; a Ready pod proves the volume was also
# attached and mounted (the kubelet mounts it before starting containers).
kubectl wait --for=condition=Ready pod/smoke-test-pod --timeout=180s \
  || FAIL "smoke-test-pod did not become Ready — volume attach/mount failed"
OK "Dynamic gp3 PVC Bound + volume attached and mounted (ebs.csi.aws.com)"

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

# ── 8. IAM access (aws-iam-authenticator) ────────────────────────────────────
# Everything above ran on the BREAK-GLASS kubeconfig (SSM static cert) — its
# continued validity is itself part of the acceptance criteria (ADR-005).
OK "Break-glass kubeconfig (SSM) works — sections 1-7 ran on it"

command -v aws-iam-authenticator >/dev/null 2>&1 \
  || FAIL "aws-iam-authenticator client not installed on this runner (pin v0.7.18)"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
CLUSTER_ID="${ACCOUNT_ID}.${AWS_REGION}.${CLUSTER_NAME}"

# First STS, then Kubernetes: a failed assume-role is an IAM problem and must
# read as one — not as an authenticator or RBAC failure. Never print tokens.
#
# The stable roles trust ONLY the SSO bridge roles and the CI OIDC role.
# A local run under any other identity (e.g. AdministratorAccess) gets
# AccessDenied BY DESIGN: in CI (GITHUB_ACTIONS=true) this section is
# mandatory; locally that specific denial skips it with a warning — the
# human path is verified via `make kubeconfig-admin` with a bridge profile.
SKIP_IAM=false
for ACCESS_ROLE in platform-admin developer; do
  set +e
  ASSUME_ERR=$(aws sts assume-role \
    --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-${ACCESS_ROLE}" \
    --role-session-name "smoke-${ACCESS_ROLE}" \
    --query 'AssumedRoleUser.Arn' --output text 2>&1 >/dev/null)
  ASSUME_RC=$?
  set -e
  if [ "${ASSUME_RC}" -ne 0 ]; then
    if [ "${GITHUB_ACTIONS:-false}" != "true" ] && echo "${ASSUME_ERR}" | grep -q "AccessDenied"; then
      echo "⚠ IAM access checks SKIPPED: this local identity cannot assume ${CLUSTER_NAME}-${ACCESS_ROLE}"
      echo "  (trust = SSO bridges + CI role only — working as designed; CI enforces this section)"
      SKIP_IAM=true
      break
    fi
    FAIL "sts:AssumeRole failed for ${CLUSTER_NAME}-${ACCESS_ROLE} (IAM side, not Kubernetes)"
  fi
done

if [ "${SKIP_IAM}" != "true" ]; then
OK "sts:AssumeRole works for both access roles"

# Ephemeral IAM kubeconfigs: endpoint+CA reused from the break-glass one.
IAM_SERVER=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}')
IAM_CA=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

make_iam_kubeconfig() {
  cat > "$2" <<IAMCFG
apiVersion: v1
kind: Config
clusters:
  - name: smoke
    cluster: {server: "${IAM_SERVER}", certificate-authority-data: "${IAM_CA}"}
contexts:
  - name: smoke
    context: {cluster: smoke, user: iam}
current-context: smoke
users:
  - name: iam
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: aws-iam-authenticator
        args: [token, -i, "${CLUSTER_ID}", -r, "arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-$1", --forward-session-name]
        interactiveMode: Never
IAMCFG
}

ADMIN_KC=$(mktemp) && DEV_KC=$(mktemp)
cleanup_iam() {
  KUBECONFIG="${ADMIN_KC}" kubectl -n logistics delete deployment smoke-dev-access \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -f "${ADMIN_KC}" "${DEV_KC}"
}
trap 'cleanup_pvc; cleanup_iam' EXIT
make_iam_kubeconfig platform-admin "${ADMIN_KC}"
make_iam_kubeconfig developer "${DEV_KC}"

KUBECONFIG="${ADMIN_KC}" kubectl get nodes >/dev/null \
  || FAIL "IAM platform-admin kubeconfig cannot list nodes"
OK "IAM platform-admin: kubectl get nodes works"

KUBECONFIG="${DEV_KC}" kubectl -n logistics create deployment smoke-dev-access \
  --image=registry.k8s.io/pause:3.10 >/dev/null \
  || FAIL "IAM developer cannot create a deployment in logistics"
OK "IAM developer: create deployment in logistics works"

# Negative test with teeth: it only passes on a REAL RBAC denial. A timeout
# or an authenticator error is a failure, not a lucky Forbidden.
set +e
DENIED_OUT=$(KUBECONFIG="${DEV_KC}" kubectl get pods -n infra 2>&1)
DENIED_RC=$?
set -e
if [ "${DENIED_RC}" -eq 0 ]; then
  FAIL "IAM developer can read pods in infra — segregation broken"
fi
echo "${DENIED_OUT}" | grep -q "Forbidden" \
  || FAIL "developer denial was not an RBAC Forbidden (got: ${DENIED_OUT})"
OK "IAM developer: infra is Forbidden (RBAC denial, not an error)"
fi

# ── 9. Network policies (IMDS deny + logistics default-deny) ─────────────────
# Positive checks FIRST: broken DNS or broken egress make every negative
# test pass for the wrong reason.
type cleanup_iam >/dev/null 2>&1 || cleanup_iam() { :; }
cleanup_netpol() {
  kubectl -n infra delete pod smoke-target --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n infra delete svc smoke-target --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n default delete pod smoke-ctl --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n logistics delete pod smoke-app --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap 'cleanup_pvc; cleanup_iam; cleanup_netpol' EXIT

hubble_drops_to_imds() {
  # Prints DROPPED flows towards IMDS as seen by every cilium agent
  for CILIUM_POD in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
    kubectl -n kube-system exec "${CILIUM_POD}" -c cilium-agent -- \
      hubble observe --verdict DROPPED --to-ip 169.254.169.254 --last 100 2>/dev/null || true
  done
}

# Temporary HTTP target in infra + control pod in default (a namespace with
# NO egress policy — using logistics here would false-positive on its own
# default-deny) + app pod in logistics.
kubectl -n infra run smoke-target --image=registry.k8s.io/e2e-test-images/agnhost:2.47 \
  --restart=Never --port=8080 -- netexec --http-port=8080 >/dev/null
kubectl -n infra expose pod smoke-target --port=80 --target-port=8080 --name=smoke-target >/dev/null
kubectl -n default run smoke-ctl --image=busybox:1.36 --restart=Never -- sleep 600 >/dev/null
kubectl -n logistics run smoke-app --image=busybox:1.36 --restart=Never -- sleep 600 >/dev/null
kubectl -n infra wait --for=condition=Ready pod/smoke-target --timeout=120s >/dev/null \
  || FAIL "smoke-target pod not Ready in infra"
kubectl -n default wait --for=condition=Ready pod/smoke-ctl --timeout=120s >/dev/null \
  || FAIL "smoke-ctl pod not Ready in default"
kubectl -n logistics wait --for=condition=Ready pod/smoke-app --timeout=120s >/dev/null \
  || FAIL "smoke-app pod not Ready in logistics"

# 9a. POSITIVE: DNS resolves from logistics (its default-deny must leave
# kube-dns open or every later negative is meaningless)
kubectl -n logistics exec smoke-app -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 \
  || FAIL "DNS from logistics broken — default-deny is eating kube-dns"
OK "DNS resolves from logistics (positive baseline)"

# 9b. POSITIVE: the control pod has working general egress
kubectl -n default exec smoke-ctl -- wget -q -T 5 -O /dev/null http://smoke-target.infra.svc.cluster.local 2>/dev/null \
  || FAIL "control pod (default) cannot reach infra service — negatives would be meaningless"
OK "Control pod (default) reaches infra service (positive baseline)"

# 9c. NEGATIVE: IMDS unreachable from the pod network, with Hubble evidence
set +e
kubectl -n default exec smoke-ctl -- wget -q -T 5 -O /dev/null http://169.254.169.254/latest/meta-data/ >/dev/null 2>&1
IMDS_RC=$?
set -e
[ "${IMDS_RC}" -ne 0 ] || FAIL "IMDS reachable from the pod network — CCNP deny not effective"
# Precise --from-pod filter: an unfiltered '--last N' window gets flooded
# by unrelated drops and produces flaky misses.
IMDS_DROP=""
for CILIUM_POD in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  HUBBLE_OUT=$(kubectl -n kube-system exec "${CILIUM_POD}" -c cilium-agent -- \
    hubble observe --verdict DROPPED --from-pod default/smoke-ctl \
    --to-ip 169.254.169.254 --last 20 2>/dev/null || true)
  if echo "${HUBBLE_OUT}" | grep -q "DROPPED"; then
    IMDS_DROP=yes
    break
  fi
done
[ -n "${IMDS_DROP}" ] \
  || FAIL "IMDS attempt did not appear as a Hubble DROP (a timeout is not a policy verdict)"
OK "IMDS denied from pod network (request fails + Hubble DROP confirmed)"

# 9d. CSI exception verified via Hubble — avoids the STS-cache false
# negative: the controller holds cached credentials (~1h), so 'PVC still
# mounts' would stay green for an hour even with a broken selector. No
# DROP towards IMDS may exist from the CSI pods. Definitive validation is
# the next fresh apply.
CSI_DROPS=$(hubble_drops_to_imds || true)
if echo "${CSI_DROPS}" | grep -q "ebs-csi"; then
  FAIL "IMDS drops from EBS CSI pods — the deny exception selector is wrong"
fi
OK "EBS CSI exception verified (no IMDS drops from CSI pods)"

# 9e. NEGATIVE: logistics cannot reach infra (name resolves, connection dropped)
kubectl -n logistics exec smoke-app -- nslookup smoke-target.infra.svc.cluster.local >/dev/null 2>&1 \
  || FAIL "smoke-target name does not resolve from logistics (DNS should be open)"
set +e
kubectl -n logistics exec smoke-app -- wget -q -T 5 -O /dev/null http://smoke-target.infra.svc.cluster.local >/dev/null 2>&1
DENY_RC=$?
set -e
[ "${DENY_RC}" -ne 0 ] || FAIL "logistics reaches infra — default-deny not effective"
NP_DROP=""
for CILIUM_POD in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  HUBBLE_OUT=$(kubectl -n kube-system exec "${CILIUM_POD}" -c cilium-agent -- \
    hubble observe --verdict DROPPED --from-pod logistics/smoke-app --last 20 2>/dev/null || true)
  if echo "${HUBBLE_OUT}" | grep -q "DROPPED"; then
    NP_DROP=yes
    break
  fi
done
[ -n "${NP_DROP}" ] || FAIL "logistics→infra denial did not appear as a Hubble DROP"
OK "logistics→infra denied (resolves, connection dropped, Hubble DROP confirmed)"

echo ""
echo "✓ Smoke test passed: cluster, platform, IAM access and network policies are healthy"
