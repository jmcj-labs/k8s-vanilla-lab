#!/usr/bin/env bash
# Smoke test for k8s-vanilla-lab: cluster + platform layer.
# Invoked by `make smoke-test` with KUBECONFIG pointing at a temp file
# fetched from SSM. Exits non-zero on the first failed check.
#
# Checks:
#   1. All nodes Ready (EXPECTED_NODES, default 6: 3 CPs + 3 workers)
#   2. No kube-proxy pods (kube-proxy-free bootstrap)
#   3. Cilium reports KubeProxyReplacement: True
#   4. spec.providerID set on every node
#   5. Dynamic gp3 PVC reaches Bound (create/verify/clean)
#   6. Gateway infra/shared-gw Accepted=True and Programmed=True
#   7. CNPG and Strimzi operator pods Running

set -euo pipefail

FAIL() { echo "✗ $*" >&2; exit 1; }
# The suite reports how many checks it ran, from a counter -- not from whoever
# is counting ✓ lines afterwards. Three different figures for this suite
# circulated in one day because the closing banner is itself a ✓ and got
# counted as a check. A number that matters is a datum, not a tally.
CHECKS_OK=0
OK() { CHECKS_OK=$((CHECKS_OK + 1)); echo "✓ $*"; }

# PREFLIGHT, genuinely first: before sourcing anything and before any external
# process at all. It used to sit below, after `dirname` had already run, which
# contradicted the contract it states -- and made the case impossible to test
# with a trimmed PATH, because the script died on the missing dirname instead
# of reaching the decision.
#
# It is also before any temporary resource is created. Two polls below bound
# their AWS call with GNU timeout, which macOS does not ship. Without it the `until` loop never satisfies its
# condition and the run dies 300s later blaming the infrastructure -- "NLB
# targets not ALL healthy" -- for a tool that was simply absent. A missing
# tool must never be reported as a sick cluster.
#
# gtimeout is the fallback because `brew install coreutils` does not by itself
# put an unprefixed `timeout` on PATH: Homebrew prefixes the GNU tools with g
# so they do not shadow the system ones.
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN=gtimeout
else
  FAIL "GNU timeout is required; on macOS: brew install coreutils"
fi

# SCRIPT_DIR without spawning a process: `dirname` is external, and nothing
# external may run before the preflight above. Parameter expansion + builtins.
_SMOKE_SRC="${BASH_SOURCE[0]}"
case "${_SMOKE_SRC}" in
  */*) _SMOKE_DIR="${_SMOKE_SRC%/*}" ;;
  *)   _SMOKE_DIR="." ;;
esac
SCRIPT_DIR=$(cd "${_SMOKE_DIR}" && pwd)
# shellcheck source=scripts/lib/envoy-e2e-verdict.sh
. "${SCRIPT_DIR}/lib/envoy-e2e-verdict.sh"

EXPECTED_NODES="${EXPECTED_NODES:-6}"

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

# ── 3. Cilium 1.20.1 and live kube-proxy replacement on every node ──────────
CILIUM_JSON=$(kubectl -n kube-system get pods -l k8s-app=cilium -o json)
echo "${CILIUM_JSON}" | jq -e --argjson expected "${EXPECTED_NODES}" '
  (.items | length) == $expected
  and all(.items[]; .status.phase == "Running"
      and (.status.containerStatuses | length) > 0
      and all(.status.containerStatuses[]; .ready == true)
      and any(.spec.containers[]; .name == "cilium-agent" and (.image | contains(":v1.20.1"))))' >/dev/null \
  || FAIL "actual cilium-agent pods are not ${EXPECTED_NODES}/${EXPECTED_NODES} Running+Ready on v1.20.1"

# Read into the array without mapfile: it is a bash 4 builtin and macOS ships
# bash 3.2, so this line aborted the suite on the project's own primary dev
# platform -- long before reaching 15d, the check that claims to be "run
# locally". Portable form, same result.
CILIUM_PODS=()
while IFS= read -r CILIUM_POD_NAME; do
  CILIUM_PODS+=("${CILIUM_POD_NAME}")
done < <(echo "${CILIUM_JSON}" | jq -r '.items[].metadata.name' | sort)
for CILIUM_POD in "${CILIUM_PODS[@]}"; do
  KPR_LINE=$(kubectl -n kube-system exec "${CILIUM_POD}" -c cilium-agent -- \
    cilium-dbg status 2>/dev/null | grep -i "KubeProxyReplacement" | head -1) \
    || FAIL "could not read KPR status from live pod ${CILIUM_POD}"
  echo "  ${CILIUM_POD}: ${KPR_LINE}"
  # grep -q "True" accepted the substring ANYWHERE on the line -- a device
  # name or a future field carrying it would have passed a False datapath.
  # That is the fail-open mirror of the fail-closed parser in INCIDENTS #23.
  # Same fix on both sides: take the token, compare it exactly.
  KPR=$(printf '%s\n' "${KPR_LINE}" | awk '$1 == "KubeProxyReplacement:" {print $2; exit}')
  [ "${KPR}" = "True" ] \
    || FAIL "${CILIUM_POD} reports KubeProxyReplacement='${KPR}' (expected exactly True)"
done

CILIUM_DS=$(kubectl -n kube-system get ds cilium -o json)
echo "${CILIUM_DS}" | jq -e --argjson expected "${EXPECTED_NODES}" '
  .status.desiredNumberScheduled == $expected
  and .status.updatedNumberScheduled == $expected
  and .status.numberReady == $expected' >/dev/null \
  || FAIL "cilium DaemonSet is not desired=updated=ready=${EXPECTED_NODES}"

OP_JSON=$(kubectl -n kube-system get deployment cilium-operator -o json)
echo "${OP_JSON}" | jq -e '
  .status.replicas == .spec.replicas
  and .status.updatedReplicas == .spec.replicas
  and .status.readyReplicas == .spec.replicas' >/dev/null \
  || FAIL "cilium-operator is not desired=updated=ready"
kubectl -n kube-system get pods -l name=cilium-operator -o json | jq -e '
  (.items | length) > 0
  and all(.items[]; .status.phase == "Running"
      and (.status.containerStatuses | length) > 0
      and all(.status.containerStatuses[]; .ready == true)
      and any(.spec.containers[]; .image | contains(":v1.20.1")))' >/dev/null \
  || FAIL "actual cilium-operator pods are not Running+Ready on v1.20.1"

ENVOY_DS=$(kubectl -n kube-system get ds cilium-envoy -o json)
echo "${ENVOY_DS}" | jq -e --argjson expected "${EXPECTED_NODES}" '
  .status.desiredNumberScheduled == $expected
  and .status.updatedNumberScheduled == $expected
  and .status.numberReady == $expected' >/dev/null \
  || FAIL "cilium-envoy DaemonSet is not desired=updated=ready=${EXPECTED_NODES}"

# Its checks are its own, so they are counted from what it actually printed
# rather than added as a constant here -- a hardcoded 10 would drift the day
# that script gains or loses an assertion.
SCHEMA_OUT=$(bash "${SCRIPT_DIR}/verify-cilium-120-schema.sh") \
  || { printf '%s\n' "${SCHEMA_OUT}"; FAIL "Gateway API live schema is not the exact v1.6.1 hybrid required by Cilium 1.20.1"; }
printf '%s\n' "${SCHEMA_OUT}"
CHECKS_OK=$((CHECKS_OK + $(printf '%s\n' "${SCHEMA_OUT}" | grep -c '✓')))
OK "Cilium 1.20.1: ${EXPECTED_NODES}/${EXPECTED_NODES} agents and Envoys Ready, operator Ready, KPR=True on every node; schema exact"

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

# ── 6b. Per-node readiness aggregator (Pieza 0 / INCIDENTS #20) ─────────────
# The signal the NLB health check now depends on. Three separate assertions,
# because "the DaemonSet is Ready", "it is not on a control plane" and "the
# endpoint answers 200" are different claims: the first two are Kubernetes'
# opinion, the third is what the balancer actually reads.
NR_JSON=$(kubectl -n infra get ds node-readiness -o json 2>/dev/null) \
  || FAIL "node-readiness DaemonSet not found in infra"
WORKER_COUNT=$(( EXPECTED_NODES - 3 ))
echo "${NR_JSON}" | jq -e --argjson w "${WORKER_COUNT}" '
  .status.desiredNumberScheduled == $w
  and .status.numberReady == $w
  and .status.updatedNumberScheduled == $w' >/dev/null \
  || FAIL "node-readiness is not desired=updated=ready=${WORKER_COUNT} (workers only)"
OK "node-readiness DaemonSet ${WORKER_COUNT}/${WORKER_COUNT} Ready on the workers"

NR_CP=$(kubectl -n infra get pods -l app.kubernetes.io/name=node-readiness \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | while read -r n; do
    [ -n "${n}" ] || continue
    kubectl get node "${n}" -o jsonpath='{.metadata.labels}' \
      | grep -q 'node-role.kubernetes.io/control-plane' && echo "${n}"
  done | wc -l | tr -d ' ')
[ "${NR_CP}" -eq 0 ] || FAIL "node-readiness is scheduled on ${NR_CP} control plane(s)"
OK "node-readiness absent from every control plane (the Gateway does not serve there)"

# The endpoint itself, on each worker's own address and port -- the same ones
# the NLB probes.
NR_PORT="${READINESS_PORT:-8910}"
NR_BAD=""
NR_NOTMINE=""
for NR_IP in $(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'); do
  [ -n "${NR_IP}" ] || continue
  # Body and code in one request: -w appends the code on its own last line, so
  # the aggregator's own output stays intact above it.
  NR_OUT=$(kubectl -n infra run "smoke-nr-$(echo "${NR_IP}" | tr '.' '-')" \
    --image=curlimages/curl:8.11.1 --restart=Never --rm -i --quiet --command -- \
    curl -s -w '\n%{http_code}' --max-time 5 \
    "http://${NR_IP}:${NR_PORT}/healthz" 2>/dev/null | tr -d '\r')
  NR_CODE=$(printf '%s' "${NR_OUT}" | tail -n1)
  NR_BODY=$(printf '%s' "${NR_OUT}" | sed '$d')
  [ "${NR_CODE}" = "200" ] || NR_BAD="${NR_BAD} ${NR_IP}=${NR_CODE:-no-answer}"

  # WHOSE port is this? A 200 alone does not prove the aggregator is the process
  # holding it -- :9890 was already taken by cilium-agent (INCIDENTS #28), and
  # any future squatter that answers 200 would satisfy the check above while the
  # NLB is told the node serves. So assert the answer carries this component's
  # own shape: the verdict line plus one line per named upstream.
  printf '%s' "${NR_BODY}" | head -n1 | grep -qx 'ready' \
    && printf '%s' "${NR_BODY}" | grep -qE '^agent +ok ' \
    && printf '%s' "${NR_BODY}" | grep -qE '^envoy +ok ' \
    || NR_NOTMINE="${NR_NOTMINE} ${NR_IP}"
done
[ -z "${NR_BAD}" ] || FAIL "node-readiness did not answer 200 on:${NR_BAD}"
OK "node-readiness answers HTTP 200 on :${NR_PORT} on every worker"

[ -z "${NR_NOTMINE}" ] || FAIL \
  "something other than node-readiness answers :${NR_PORT} on:${NR_NOTMINE} (port collision)"
OK "the process answering :${NR_PORT} is node-readiness itself on every worker"

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

# RBAC surface (contract 3b): the developer can create the app's routing
# objects, but not jobs (migrations are auto-migrate) nor anything in data.
[ "$(KUBECONFIG="${DEV_KC}" kubectl auth can-i create grpcroutes -n logistics 2>/dev/null)" = "yes" ] \
  || FAIL "developer cannot create grpcroutes in logistics (contract 3b)"
[ "$(KUBECONFIG="${DEV_KC}" kubectl auth can-i create jobs -n logistics 2>/dev/null)" = "no" ] \
  || FAIL "developer CAN create jobs in logistics — not in the contract"
[ "$(KUBECONFIG="${DEV_KC}" kubectl auth can-i get pods -n data 2>/dev/null)" = "no" ] \
  || FAIL "developer CAN read pods in data — segregation broken"
OK "IAM developer RBAC: grpcroutes yes · jobs no · data no"
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

# ── 10. Data layer (CNPG + Kafka + operand policies) ─────────────────────────
# The operand policies are applied by install.sh BEFORE the smoke runs, so
# every check here is a post-policy positive: replication, failover and
# produce/consume working now proves the policies did not strangle them.
cleanup_data() {
  kubectl -n data delete kafkatopic smoke-topic --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n logistics delete pod smoke-kafka-client --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n logistics delete secret smoke-kafka-ca --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n default delete pod smoke-neutral --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap 'cleanup_pvc; cleanup_iam; cleanup_netpol; cleanup_data' EXIT

# 10a. CNPG healthy + one instance per worker (evidence: -o wide)
PG_PHASE=$(kubectl -n data get cluster logistics-pg -o jsonpath='{.status.phase}')
[ "${PG_PHASE}" = "Cluster in healthy state" ] || FAIL "CNPG cluster not healthy (phase: ${PG_PHASE})"
kubectl -n data get pods -l cnpg.io/cluster=logistics-pg -o wide
PG_NODES=$(kubectl -n data get pods -l cnpg.io/cluster=logistics-pg \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | grep -c . || true)
[ "${PG_NODES}" -eq 3 ] || FAIL "PG instances on ${PG_NODES} workers, expected 3 (required anti-affinity)"
OK "CNPG healthy: 3 instances on 3 distinct workers"

# 10b. FAILOVER — the crown jewel: kill the primary, the operator promotes,
# the cluster returns to healthy with a DIFFERENT primary.
# Guard (INCIDENTS #13): never kill the primary while a backup is running.
# Backups target prefer-standby, but in a degraded state CNPG may fall back
# to the primary — and its smart shutdown then holds the terminating pod up
# to 1800s waiting for the backup, wedging the 300s failover wait.
BK_ELAPSED=0
while kubectl -n data get backup -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -qw running; do
  if [ "${BK_ELAPSED}" -ge 600 ]; then
    FAIL "a CNPG backup has been running for over 600s — not safe to run the failover drill"
  fi
  echo "  backup in flight — waiting before the failover drill (${BK_ELAPSED}s)"
  sleep 15
  BK_ELAPSED=$((BK_ELAPSED + 15))
done
OLD_PRIMARY=$(kubectl -n data get cluster logistics-pg -o jsonpath='{.status.currentPrimary}')
echo "  primary before: ${OLD_PRIMARY}"
kubectl -n data delete pod "${OLD_PRIMARY}" --wait=false >/dev/null
FAILOVER_OK=""
for _ in $(seq 1 60); do
  sleep 5
  PHASE=$(kubectl -n data get cluster logistics-pg -o jsonpath='{.status.phase}' 2>/dev/null || true)
  NEW_PRIMARY=$(kubectl -n data get cluster logistics-pg -o jsonpath='{.status.currentPrimary}' 2>/dev/null || true)
  if [ "${PHASE}" = "Cluster in healthy state" ] && [ -n "${NEW_PRIMARY}" ] && [ "${NEW_PRIMARY}" != "${OLD_PRIMARY}" ]; then
    FAILOVER_OK=yes
    break
  fi
done
[ -n "${FAILOVER_OK}" ] || FAIL "CNPG failover did not complete in 300s (phase: ${PHASE:-?}, primary: ${NEW_PRIMARY:-?})"
OK "CNPG failover: ${OLD_PRIMARY} → ${NEW_PRIMARY}, healthy again in <5min"

# 10c. Kafka Ready, spread, and an RF3 test topic via the topic operator
kubectl -n data wait kafka/logistics-kafka --for=condition=Ready --timeout=120s >/dev/null \
  || FAIL "Kafka cluster not Ready"
KAFKA_NODES=$(kubectl -n data get pods -l strimzi.io/pool-name=dual \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | grep -c . || true)
[ "${KAFKA_NODES}" -eq 3 ] || FAIL "Kafka nodes on ${KAFKA_NODES} workers, expected 3 (required anti-affinity)"
kubectl apply -f - >/dev/null <<'TOPIC_EOF'
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: smoke-topic
  namespace: data
  labels:
    strimzi.io/cluster: logistics-kafka
spec:
  partitions: 3
  replicas: 3
  config:
    min.insync.replicas: 2
TOPIC_EOF
kubectl -n data wait kafkatopic/smoke-topic --for=condition=Ready --timeout=120s >/dev/null \
  || FAIL "smoke-topic (RF3) did not become Ready"
OK "Kafka: 3 KRaft nodes on 3 workers, RF3 test topic Ready"

# 10d. Produce/consume through the internal TLS listener FROM logistics
# (the only namespace the policy admits as client). CA truststore comes from
# the Strimzi cluster CA secret; the password travels via pod env, never argv.
KAFKA_IMAGE=$(kubectl -n data get pod -l strimzi.io/pool-name=dual \
  -o jsonpath='{.items[0].spec.containers[0].image}')
kubectl -n data get secret logistics-kafka-cluster-ca-cert -o jsonpath='{.data.ca\.p12}' \
  | base64 -d > /tmp/smoke-ca.p12
kubectl -n logistics create secret generic smoke-kafka-ca \
  --from-file=ca.p12=/tmp/smoke-ca.p12 \
  --from-literal=password="$(kubectl -n data get secret logistics-kafka-cluster-ca-cert -o jsonpath='{.data.ca\.password}' | base64 -d)" \
  >/dev/null
rm -f /tmp/smoke-ca.p12
kubectl -n logistics apply -f - >/dev/null <<KCLIENT_EOF
apiVersion: v1
kind: Pod
metadata:
  name: smoke-kafka-client
spec:
  restartPolicy: Never
  containers:
    - name: kafka
      image: ${KAFKA_IMAGE}
      command: ["sleep", "900"]
      env:
        - name: CA_PASS
          valueFrom:
            secretKeyRef:
              name: smoke-kafka-ca
              key: password
      volumeMounts:
        - name: ca
          mountPath: /mnt/ca
          readOnly: true
  volumes:
    - name: ca
      secret:
        secretName: smoke-kafka-ca
KCLIENT_EOF
kubectl -n logistics wait --for=condition=Ready pod/smoke-kafka-client --timeout=180s >/dev/null \
  || FAIL "kafka client pod not Ready in logistics"
kubectl -n logistics exec smoke-kafka-client -- bash -c 'cat > /tmp/client.properties <<EOF
security.protocol=SSL
ssl.truststore.location=/mnt/ca/ca.p12
ssl.truststore.password=${CA_PASS}
ssl.truststore.type=PKCS12
EOF'
kubectl -n logistics exec smoke-kafka-client -- bash -c \
  'printf "m1\nm2\nm3\n" | bin/kafka-console-producer.sh \
     --bootstrap-server logistics-kafka-kafka-bootstrap.data:9093 \
     --topic smoke-topic --producer.config /tmp/client.properties \
     --producer-property acks=all' >/dev/null 2>&1 \
  || FAIL "producing to smoke-topic over TLS from logistics failed"
CONSUMED=$(kubectl -n logistics exec smoke-kafka-client -- bash -c \
  'bin/kafka-console-consumer.sh \
     --bootstrap-server logistics-kafka-kafka-bootstrap.data:9093 \
     --topic smoke-topic --from-beginning --max-messages 3 \
     --timeout-ms 30000 --consumer.config /tmp/client.properties 2>/dev/null' \
  | grep -c '^m[0-9]*$' || true)
[ "${CONSUMED}" -eq 3 ] || FAIL "expected 3 messages consumed, got ${CONSUMED}"
OK "Kafka: RF3 topic produced+consumed over the internal TLS listener from logistics"

# 10e. Losing one broker must not stop producing (RF3 / min.insync.replicas 2)
KAFKA_VICTIM=$(kubectl -n data get pods -l strimzi.io/pool-name=dual \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n data delete pod "${KAFKA_VICTIM}" --wait=false >/dev/null
sleep 10
kubectl -n logistics exec smoke-kafka-client -- bash -c \
  'printf "m4\nm5\nm6\n" | bin/kafka-console-producer.sh \
     --bootstrap-server logistics-kafka-kafka-bootstrap.data:9093 \
     --topic smoke-topic --producer.config /tmp/client.properties \
     --producer-property acks=all' >/dev/null 2>&1 \
  || FAIL "producing with one broker down failed (ISR should hold at 2)"
OK "Kafka: producing (acks=all) survives the loss of one broker"
# leave the cluster whole before finishing
kubectl -n data wait kafka/logistics-kafka --for=condition=Ready --timeout=300s >/dev/null \
  || FAIL "Kafka did not return to Ready after broker recovery"
OK "Kafka back to Ready after broker recovery"

# 10f. Policy negatives from a NEUTRAL namespace (default): PG and Kafka
# must be unreachable, with Hubble drop evidence. TCP connect via bash
# /dev/tcp in the client pod proved the logistics-side positive already.
kubectl -n default run smoke-neutral --image=busybox:1.36 --restart=Never -- sleep 300 >/dev/null
kubectl -n default wait --for=condition=Ready pod/smoke-neutral --timeout=60s >/dev/null \
  || FAIL "smoke-neutral pod not Ready"
set +e
kubectl -n default exec smoke-neutral -- nc -z -w 4 logistics-pg-rw.data.svc.cluster.local 5432 >/dev/null 2>&1
PG_NEUTRAL_RC=$?
kubectl -n default exec smoke-neutral -- nc -z -w 4 logistics-kafka-kafka-bootstrap.data.svc.cluster.local 9093 >/dev/null 2>&1
KAFKA_NEUTRAL_RC=$?
set -e
[ "${PG_NEUTRAL_RC}" -ne 0 ] || FAIL "neutral namespace can reach PostgreSQL — data policy not effective"
[ "${KAFKA_NEUTRAL_RC}" -ne 0 ] || FAIL "neutral namespace can reach Kafka — data policy not effective"
DATA_DROP=""
for CILIUM_POD in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  HUBBLE_OUT=$(kubectl -n kube-system exec "${CILIUM_POD}" -c cilium-agent -- \
    hubble observe --verdict DROPPED --from-pod default/smoke-neutral --last 20 2>/dev/null || true)
  if echo "${HUBBLE_OUT}" | grep -q "DROPPED"; then
    DATA_DROP=yes
    break
  fi
done
[ -n "${DATA_DROP}" ] || FAIL "neutral→data denial did not appear as a Hubble DROP"
OK "Data policies: neutral namespace denied to PG and Kafka (Hubble DROP confirmed)"

# ── 11. Registry (ECR) + app CI role + platform metrics ──────────────────────
APP_REPOS="shipments-api routing tracking-events traffic-generator"
CI_ROLE="logistics-lab-ci"

# 11a. Four ECR repositories with the required config (via API, not state)
for REPO in ${APP_REPOS}; do
  REPO_JSON=$(aws ecr describe-repositories --repository-names "${REPO}" \
    --region "${AWS_REGION}" --output json 2>/dev/null) \
    || FAIL "ECR repository ${REPO} not found"
  MUT=$(echo "${REPO_JSON}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["repositories"][0]["imageTagMutability"])')
  SCAN=$(echo "${REPO_JSON}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["repositories"][0]["imageScanningConfiguration"]["scanOnPush"])')
  ENC=$(echo "${REPO_JSON}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["repositories"][0]["encryptionConfiguration"]["encryptionType"])')
  [ "${MUT}" = "IMMUTABLE" ] || FAIL "${REPO}: tag mutability ${MUT}, expected IMMUTABLE"
  [ "${SCAN}" = "True" ]     || FAIL "${REPO}: scan on push is ${SCAN}"
  [ "${ENC}" = "AES256" ]    || FAIL "${REPO}: encryption ${ENC}, expected AES256"
  aws ecr get-lifecycle-policy --repository-name "${REPO}" --region "${AWS_REGION}" >/dev/null 2>&1 \
    || FAIL "${REPO}: no lifecycle policy"
done
OK "ECR: 4 repositories IMMUTABLE + scan-on-push + AES256 + lifecycle"

# 11b. App CI role trust scoped to the app repo's main/tags — never a wildcard
CI_TRUST=$(aws iam get-role --role-name "${CI_ROLE}" \
  --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null) \
  || FAIL "CI role ${CI_ROLE} not found"
echo "${CI_TRUST}" | python3 -c '
import json,sys,re
doc=json.load(sys.stdin)
subs=doc["Statement"][0]["Condition"]["StringLike"]["token.actions.githubusercontent.com:sub"]
subs=subs if isinstance(subs,list) else [subs]
# Same repo in either naming scheme: classic org/name, or the ID-qualified
# owner@id/repo@id that immutable subject claims emit (INCIDENTS #12).
pat=re.compile(r"^repo:jmcj-labs(@[0-9]+)?/logistics-lab(@[0-9]+)?:")
assert all(pat.match(s) for s in subs), f"trust not scoped to the app repo: {subs}"
assert not any(s=="repo:*" or ":*:" in s or s.endswith(":*") and "logistics-lab" not in s for s in subs), f"wildcard too broad: {subs}"
' || FAIL "CI role trust policy is not correctly scoped to jmcj-labs/logistics-lab"
OK "logistics-lab-ci trust scoped to jmcj-labs/logistics-lab (main + tags, classic + ID-qualified sub)"

# 11c. Prometheus scrapes PostgreSQL and Kafka: up==1 and real samples.
# Bounded retries cover the scrape interval (~30s) after a fresh apply.
# The prometheus container has no shell, so query from a throwaway busybox
# pod; `grep -o '{.*}'` isolates the JSON from kubectl's "pod deleted" line.
PROM="http://kube-prometheus-stack-prometheus.infra.svc.cluster.local:9090"
prom_result_count() {
  local q="$1"
  kubectl -n infra run "smoke-promq-$$" --rm -i --restart=Never --image=busybox:1.36 -- \
    sh -c "wget -qO- '${PROM}/api/v1/query?query=$1'" 2>/dev/null \
    | grep -o '{.*}' \
    | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)["data"]["result"]))
except Exception: print(0)' 2>/dev/null || echo 0
}
prom_expect_nonempty() {
  local q="$1" label="$2" count
  for _ in $(seq 1 20); do
    count=$(prom_result_count "$q")
    [ "${count:-0}" -gt 0 ] && { OK "${label}"; return 0; }
    sleep 6
  done
  FAIL "${label}: no samples after ~2min"
}
# up==1 for both PodMonitor jobs (cnpg on 9187, kafka on 9404)
prom_expect_nonempty 'up{container="postgres"}==1' "Prometheus: PostgreSQL targets up==1"
prom_expect_nonempty 'up{namespace="data",endpoint="tcp-prometheus"}==1' "Prometheus: Kafka targets up==1"
# at least one concrete cnpg_* and one concrete kafka_* metric has samples
prom_expect_nonempty 'cnpg_collector_up' "Metric cnpg_collector_up has samples"
prom_expect_nonempty 'kafka_server_replicamanager_leadercount' "Metric kafka_server_* has samples"

# ── 12. App contract (3b): topics, projected secrets, fixtures, IAM shape ────
cleanup_contract() {
  kubectl -n logistics delete deploy smoke-metrics-fx smoke-gw-be --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n logistics delete svc smoke-gw-be --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n logistics delete httproute smoke-gw-rt --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n logistics delete pod smoke-tg smoke-scraper2 --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap 'cleanup_pvc; cleanup_iam; cleanup_netpol; cleanup_data; cleanup_contract' EXIT

# 12a. Topics Ready + auto.create disabled effective in the broker config
kubectl -n data wait --for=condition=Ready kafkatopic/shipment.created kafkatopic/route.calculated \
  --timeout=60s >/dev/null || FAIL "KafkaTopics not Ready"
AC=$(kubectl -n data exec logistics-kafka-dual-0 -- \
  cat /tmp/strimzi.properties 2>/dev/null | grep -i '^auto.create.topics.enable=' || true)
echo "${AC}" | grep -qi 'false' || FAIL "auto.create.topics.enable is not false in the broker config (${AC})"
OK "KafkaTopics Ready + auto.create.topics.enable=false effective"

# 12b. Projected secrets — full canonical hash comparison, NEVER printing
# values. PG: hash of type + the entire data map (canonical JSON). Kafka:
# hash of ca.crt AND the data key set must be exactly ["ca.crt"].
for S in logistics-pg-app logistics-kafka-cluster-ca-cert; do
  kubectl -n logistics get secret "${S}" >/dev/null 2>&1 || FAIL "projected secret ${S} missing in logistics"
done
canon_hash() {  # ns name [key] — hash of type+data, or of a single data key
  kubectl -n "$1" get secret "$2" -o json | python3 -c '
import json,sys,hashlib
s=json.load(sys.stdin); key=sys.argv[1] if len(sys.argv)>1 else None
if key:
    payload=s["data"][key]
else:
    payload=json.dumps({"type":s["type"],"data":s["data"]},sort_keys=True,separators=(",",":"))
print(hashlib.sha256(payload.encode()).hexdigest())' "${3:-}"
}
[ "$(canon_hash data logistics-pg-app)" = "$(canon_hash logistics logistics-pg-app)" ] \
  || FAIL "projected PG secret (type+data) differs from source — stale projection"
# Kafka: exactly {ca.crt}, and its content matches source
kubectl -n logistics get secret logistics-kafka-cluster-ca-cert -o json \
  | python3 -c 'import json,sys;k=sorted(json.load(sys.stdin)["data"].keys());sys.exit(0 if k==["ca.crt"] else 1)' \
  || FAIL "projected Kafka secret keys are not exactly [ca.crt] (must never carry ca.key/PKCS12)"
[ "$(canon_hash data logistics-kafka-cluster-ca-cert ca.crt)" = "$(canon_hash logistics logistics-kafka-cluster-ca-cert ca.crt)" ] \
  || FAIL "projected Kafka ca.crt differs from source — stale projection"
OK "Projected secrets: pg-app (type+data hash) + kafka {ca.crt} only, match source"

# 12c. Metrics fixture: temporary app-labeled pod, real /metrics endpoint
kubectl -n logistics apply -f - >/dev/null <<'FX'
apiVersion: apps/v1
kind: Deployment
metadata: {name: smoke-metrics-fx, namespace: logistics, labels: {app.kubernetes.io/part-of: logistics-lab}}
spec:
  replicas: 1
  selector: {matchLabels: {app: smoke-metrics-fx}}
  template:
    metadata: {labels: {app: smoke-metrics-fx, app.kubernetes.io/part-of: logistics-lab}}
    spec:
      automountServiceAccountToken: false
      containers:
        - name: app
          image: quay.io/brancz/prometheus-example-app:v0.5.0
          ports: [{name: metrics, containerPort: 8080}]
          securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, runAsUser: 65534, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}
FX
kubectl -n logistics wait --for=condition=Available deploy/smoke-metrics-fx --timeout=120s >/dev/null \
  || FAIL "metrics fixture not Available"
FX_POD=$(kubectl -n logistics get pod -l app=smoke-metrics-fx -o jsonpath='{.items[0].metadata.name}')
FXIP=$(kubectl -n logistics get pod "${FX_POD}" -o jsonpath='{.status.podIP}')
# up for THIS exact fixture pod (not a namespace-wide match)
prom_expect_nonempty "up{namespace=\"logistics\",pod=\"${FX_POD}\"}==1" "Metrics fixture: ${FX_POD} scraped up==1"
# negative: a pod in a neutral namespace cannot scrape it + Hubble drop
kubectl -n default run smoke-scraper2 --image=busybox:1.36 --restart=Never -- sleep 90 >/dev/null
kubectl -n default wait --for=condition=Ready pod/smoke-scraper2 --timeout=60s >/dev/null || FAIL "scraper pod not Ready"
set +e
kubectl -n default exec smoke-scraper2 -- wget -q -T5 -O /dev/null "http://${FXIP}:8080/metrics" >/dev/null 2>&1
SC_RC=$?
set -e
[ "${SC_RC}" -ne 0 ] || FAIL "neutral namespace scraped the fixture — metrics CNP not effective"
# Drop filtered to exactly this flow (source pod + fixture IP + port); short retry.
MFX_DROP=""
for _ in $(seq 1 5); do
  for CILIUM_POD in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
    HUBBLE_OUT=$(kubectl -n kube-system exec "${CILIUM_POD}" -c cilium-agent -- \
      hubble observe --verdict DROPPED --from-pod default/smoke-scraper2 \
      --to-ip "${FXIP}" --port 8080 --last 20 2>/dev/null || true)
    echo "${HUBBLE_OUT}" | grep -q "DROPPED" && { MFX_DROP=yes; break; }
  done
  [ -n "${MFX_DROP}" ] && break
  sleep 3
done
kubectl -n default delete pod smoke-scraper2 --wait=false >/dev/null 2>&1 || true
[ -n "${MFX_DROP}" ] || FAIL "neutral→fixture denial did not appear as a Hubble DROP (${FXIP}:8080)"
OK "Metrics fixture: up==1, neutral scrape denied (Hubble DROP on ${FXIP}:8080), CNP proven"

# 12d. Gateway egress fixture — POSITIVE ONLY (INCIDENTS #10: egress to the
# Gateway VIP is to-proxy redirected and not gated by a client CNP, so there
# is no meaningful network-policy negative to assert). Proves a logistics pod
# reaches the shared Gateway over HTTPS with SNI end to end.
GW_IP=$(kubectl -n infra get svc -l gateway.networking.k8s.io/gateway-name=shared-gw \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
[ -n "${GW_IP}" ] || FAIL "shared Gateway has no LoadBalancer IP"
kubectl -n logistics apply -f - >/dev/null <<'FX'
apiVersion: apps/v1
kind: Deployment
metadata: {name: smoke-gw-be, namespace: logistics, labels: {app: smoke-gw-be}}
spec:
  replicas: 1
  selector: {matchLabels: {app: smoke-gw-be}}
  template:
    metadata: {labels: {app: smoke-gw-be}}
    spec:
      automountServiceAccountToken: false
      containers:
        - name: web
          image: registry.k8s.io/e2e-test-images/agnhost:2.47
          args: ["netexec","--http-port=8080"]
          ports: [{containerPort: 8080}]
          securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, runAsUser: 1000, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}
---
apiVersion: v1
kind: Service
metadata: {name: smoke-gw-be, namespace: logistics}
spec:
  selector: {app: smoke-gw-be}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: smoke-gw-rt, namespace: logistics}
spec:
  parentRefs: [{name: shared-gw, namespace: infra}]
  hostnames: ["smoke.logistics.lab"]
  rules: [{backendRefs: [{name: smoke-gw-be, port: 80}]}]
FX
kubectl -n logistics wait --for=condition=Available deploy/smoke-gw-be --timeout=120s >/dev/null \
  || FAIL "gateway fixture backend not Available"
kubectl -n logistics run smoke-tg --image=curlimages/curl:8.10.1 \
  --labels="app.kubernetes.io/name=traffic-generator" --restart=Never \
  --overrides='{"spec":{"automountServiceAccountToken":false,"containers":[{"name":"c","image":"curlimages/curl:8.10.1","command":["sleep","120"],"securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"runAsUser":1000,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}]}}' >/dev/null
kubectl -n logistics wait --for=condition=Ready pod/smoke-tg --timeout=90s >/dev/null || FAIL "gateway fixture client not Ready"
HTTP_CODE=""
for _ in $(seq 1 10); do
  HTTP_CODE=$(kubectl -n logistics exec smoke-tg -- curl -sk \
    --resolve "smoke.logistics.lab:443:${GW_IP}" https://smoke.logistics.lab/hostname \
    -m 8 -o /dev/null -w "%{http_code}" 2>/dev/null || true)
  [ "${HTTP_CODE}" = "200" ] && break
  sleep 3
done
[ "${HTTP_CODE}" = "200" ] || FAIL "logistics pod did not reach the Gateway over HTTPS (got ${HTTP_CODE})"
OK "Gateway: logistics pod reaches the shared Gateway over HTTPS with SNI (HTTP 200)"

# 12e. IAM by EXACT inspection (never assumption): the runner cannot obtain
# Repo 2's OIDC identity, so verify the exact policy shapes with FULL ARNs
# anchored to this account/region (endswith would accept another account).
ACC="${ACCOUNT_ID}"
export ACC AWS_REGION
DEV_ARN="arn:aws:iam::${ACC}:role/k8s-vanilla-lab-developer"
CI_ARN="arn:aws:iam::${ACC}:role/logistics-lab-ci"
ECR_ARNS=$(python3 -c 'import os;acc=os.environ["ACC"];r=os.environ["AWS_REGION"];print(",".join(f"arn:aws:ecr:{r}:{acc}:repository/{n}" for n in ["shipments-api","routing","tracking-events","traffic-generator"]))')

# (a) logistics-lab-ci: inline set EXACTLY the two; zero managed; ECR actions
#     + FULL resource ARN set (set equality); assume = exactly one AssumeRole
#     on the full developer ARN.
CI_INLINE=$(aws iam list-role-policies --role-name logistics-lab-ci --query 'sort(PolicyNames)' --output json 2>/dev/null || echo '[]')
echo "${CI_INLINE}" | python3 -c 'import json,sys;assert json.load(sys.stdin)==["logistics-lab-ci-assume-developer","logistics-lab-ci-ecr-push"]' \
  || FAIL "logistics-lab-ci inline policy set is not exactly the two expected"
aws iam list-attached-role-policies --role-name logistics-lab-ci --query 'AttachedPolicies' --output json 2>/dev/null \
  | python3 -c 'import json,sys;assert json.load(sys.stdin)==[]' \
  || FAIL "logistics-lab-ci has unexpected managed policies attached"
aws iam get-role-policy --role-name logistics-lab-ci --policy-name logistics-lab-ci-ecr-push \
  --query 'PolicyDocument' --output json 2>/dev/null | ECR_ARNS="${ECR_ARNS}" python3 -c '
import json,sys,os
st={s["Sid"]:s for s in json.load(sys.stdin)["Statement"]}
assert set(st)=={"ECRAuthToken","PushPullAppRepositories"}, "unexpected ECR policy Sids"
a=st["ECRAuthToken"]; assert a["Effect"]=="Allow" and a["Action"]=="ecr:GetAuthorizationToken" and a["Resource"]=="*"
p=st["PushPullAppRepositories"]; assert p["Effect"]=="Allow"
assert set(p["Action"])=={"ecr:BatchCheckLayerAvailability","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer","ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage"}, "ECR push action set differs"
res=p["Resource"] if isinstance(p["Resource"],list) else [p["Resource"]]
assert set(res)==set(os.environ["ECR_ARNS"].split(",")), "ECR resource ARN set is not exactly the four repos"
' || FAIL "logistics-lab-ci ECR policy is not exact (actions/resources/Sids)"
aws iam get-role-policy --role-name logistics-lab-ci --policy-name logistics-lab-ci-assume-developer \
  --query 'PolicyDocument' --output json 2>/dev/null | DEV_ARN="${DEV_ARN}" python3 -c '
import json,sys,os
st=json.load(sys.stdin)["Statement"]
assert len(st)==1
s=st[0]; assert s["Effect"]=="Allow" and s["Action"]=="sts:AssumeRole" and s["Resource"]==os.environ["DEV_ARN"]
' || FAIL "assume-developer policy is not exactly AssumeRole on the full developer ARN"

# (b) developer trust: EXACT Sid set; app-CI = root of THIS account + ArnEquals
#     on the FULL ci ARN; Identity Center + infra-CI statements preserved.
aws iam get-role --role-name k8s-vanilla-lab-developer --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null \
  | ACC="${ACC}" CI_ARN="${CI_ARN}" python3 -c '
import json,sys,os
st={s["Sid"]:s for s in json.load(sys.stdin)["Statement"]}
assert set(st)=={"IdentityCenterBridge","CISmokeTest","AppCIAssumesDeveloper"}, f"developer trust Sid set differs: {set(st)}"
a=st["AppCIAssumesDeveloper"]
assert a["Effect"]=="Allow" and a["Action"]=="sts:AssumeRole"
assert a["Principal"]["AWS"]=="arn:aws:iam::"+os.environ["ACC"]+":root", "app-CI principal is not this account root"
assert a["Condition"]["ArnEquals"]["aws:PrincipalArn"]==os.environ["CI_ARN"], "ArnEquals is not the full ci ARN"
' || FAIL "developer trust is not exactly the expected three statements / full ARNs"

# (c) app CI ABSENT from the platform-admin trust.
aws iam get-role --role-name k8s-vanilla-lab-platform-admin --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null \
  | python3 -c 'import json,sys;assert "logistics-lab-ci" not in json.dumps(json.load(sys.stdin))' \
  || FAIL "logistics-lab-ci must NOT appear in platform-admin trust"
OK "IAM exact: full-ARN set equality on logistics-lab-ci policies + developer trust; platform-admin clean"

# ── 12. Backups flowing to S3 (S2 piece 1) ───────────────────────────────────
# Verifies the backup PATH on every apply. Restore is NOT checked here — that
# is the drills' job (docs/RUNBOOK-restore-*.md), a documented ceremony, not
# a per-apply gate.
BACKUP_BUCKET="${BACKUP_BUCKET:-${CLUSTER_NAME}-backups-${ACCOUNT_ID}}"

# 12a. etcd: CronJob present, then a triggered run proves the whole path
# (scheduling on the CP, host PKI, snapshot, instance-role S3 write).
kubectl -n kube-system get cronjob etcd-backup >/dev/null 2>&1 \
  || FAIL "etcd-backup CronJob not found in kube-system"
SMOKE_JOB="etcd-backup-smoke-$$"
cleanup_backup_job() {
  kubectl -n kube-system delete job "${SMOKE_JOB}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap 'cleanup_pvc; cleanup_iam; cleanup_netpol; cleanup_data; cleanup_contract; cleanup_backup_job' EXIT
SNAP_SINCE=$(date -u +%s)
kubectl -n kube-system create job --from=cronjob/etcd-backup "${SMOKE_JOB}" >/dev/null
kubectl -n kube-system wait --for=condition=complete "job/${SMOKE_JOB}" --timeout=300s \
  || FAIL "triggered etcd backup job did not complete in 300s"
LAST_SNAP=$(aws s3api list-objects-v2 --bucket "${BACKUP_BUCKET}" --prefix etcd/ \
  --query 'sort_by(Contents,&LastModified)[-1].[Key,LastModified]' --output text 2>/dev/null)
[ -n "${LAST_SNAP}" ] && [ "${LAST_SNAP}" != "None" ] \
  || FAIL "no object under etcd/ in ${BACKUP_BUCKET} after the triggered backup"
LAST_SNAP_EPOCH=$(python3 -c 'import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp()))' "$(echo "${LAST_SNAP}" | awk '{print $2}')")
[ "${LAST_SNAP_EPOCH}" -ge "$((SNAP_SINCE - 60))" ] \
  || FAIL "newest etcd/ object predates the triggered backup (${LAST_SNAP})"
cleanup_backup_job
OK "etcd backup: CronJob present + triggered snapshot landed in s3://${BACKUP_BUCKET}/etcd/"

# 12b. CNPG: credentials Secret present (hash only — never the values).
CREDS_HASH=$(kubectl -n data get secret cnpg-backup-creds -o json 2>/dev/null \
  | python3 -c 'import json,sys,hashlib;d=json.load(sys.stdin)["data"];print(hashlib.sha256(json.dumps(d,sort_keys=True).encode()).hexdigest()[:12])') \
  || FAIL "data/cnpg-backup-creds Secret not present"
OK "cnpg-backup-creds present in data (sha256 ${CREDS_HASH})"

# 12c. CNPG: first base backup completed (the ScheduledBackup is immediate,
# so a fresh apply converges within minutes) + WAL archiving green.
ELAPSED=0
until kubectl -n data get backup -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q completed; do
  if [ "${ELAPSED}" -ge 420 ]; then
    FAIL "no CNPG base backup reached phase=completed within 420s"
  fi
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done
ARCHIVING=$(kubectl -n data get cluster logistics-pg \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}')
[ "${ARCHIVING}" = "True" ] || FAIL "ContinuousArchiving condition is '${ARCHIVING}', expected True"
OK "CNPG: first base backup completed + WAL archiving (ContinuousArchiving=True) → s3://${BACKUP_BUCKET}/cnpg/"

# ── 13. NLB — the single public APPLICATION entry (S2 piece 2) ───────────────
GATEWAY_NODEPORT="${GATEWAY_NODEPORT:-30443}"
NLB_NAME="${CLUSTER_NAME}-gw-nlb"

# 13a. NLB active, TCP/443 listener
NLB_JSON=$(aws elbv2 describe-load-balancers --names "${NLB_NAME}" --region "${AWS_REGION}" 2>/dev/null) \
  || FAIL "NLB ${NLB_NAME} not found"
read -r NLB_ARN NLB_DNS NLB_STATE NLB_SG <<< "$(echo "${NLB_JSON}" | python3 -c '
import json,sys
lb=json.load(sys.stdin)["LoadBalancers"][0]
print(lb["LoadBalancerArn"], lb["DNSName"], lb["State"]["Code"], lb["SecurityGroups"][0])')"
[ "${NLB_STATE}" = "active" ] || FAIL "NLB state is ${NLB_STATE}, want active"
# Select by port, never Listeners[0]: since piece 3 the NLB carries TWO
# listeners (443 application + 6443 API) and the API order is not defined.
aws elbv2 describe-listeners --load-balancer-arn "${NLB_ARN}" --region "${AWS_REGION}" \
  --query 'Listeners[?Port==`443`].Protocol' --output text | grep -q "^TCP$" \
  || FAIL "NLB has no TCP/443 listener"
OK "NLB active with TCP/443 listener (${NLB_DNS})"

# 13b. Target set == EXACTLY the worker instance IDs, and ALL healthy.
# Runs AFTER the platform install by design: the NLB is born unhealthy
# during tofu apply (the NodePort only answers once Cilium programs the
# Gateway) — that ordering is expected, not a failure.
# Select the APPLICATION target group by name — TargetGroups[0] is
# ambiguous now that the API TG shares the NLB (piece 3).
TG_ARN=$(aws elbv2 describe-target-groups --names "${CLUSTER_NAME}-gw-tg" --region "${AWS_REGION}" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
TG_PORT=$(aws elbv2 describe-target-groups --target-group-arns "${TG_ARN}" --region "${AWS_REGION}" \
  --query 'TargetGroups[0].Port' --output text)
WORKER_IDS=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:Role,Values=worker" \
            "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n' | sort)
HEALTH_START=$(date +%s)
TARGETS_JSON='{"TargetHealthDescriptions":[]}'
until TARGETS_JSON=$("${TIMEOUT_BIN}" 15 aws elbv2 describe-target-health \
      --target-group-arn "${TG_ARN}" --region "${AWS_REGION}" \
      --cli-connect-timeout 5 --cli-read-timeout 10) \
  && [ "$(echo "${TARGETS_JSON}" | python3 -c '
import json,sys
t=json.load(sys.stdin)["TargetHealthDescriptions"]
print("ok" if t and all(d["TargetHealth"]["State"]=="healthy" for d in t) else "no")')" = "ok" ]; do
  HEALTH_ELAPSED=$(( $(date +%s) - HEALTH_START ))
  if [ "${HEALTH_ELAPSED}" -ge 300 ]; then
    echo "${TARGETS_JSON}" | python3 -c 'import json,sys; [print(" ", d["Target"]["Id"], d["TargetHealth"]["State"]) for d in json.load(sys.stdin)["TargetHealthDescriptions"]]' || true
    FAIL "NLB targets not ALL healthy after 300s"
  fi
  sleep 15
done
TARGET_IDS=$(echo "${TARGETS_JSON}" | python3 -c '
import json,sys
print("\n".join(sorted(d["Target"]["Id"] for d in json.load(sys.stdin)["TargetHealthDescriptions"])))')
[ "${TARGET_IDS}" = "${WORKER_IDS}" ] || FAIL "target set differs from worker instance set"
OK "NLB targets: exactly the $(echo "${WORKER_IDS}" | wc -l | tr -d ' ') workers, ALL healthy"

# 13c. Port coherence: Service == target group == worker SG rule (from the
# NLB's SG only). Drift in any of the three is a broken entrance.
SVC_NP=$(kubectl -n infra get svc cilium-gateway-shared-gw -o jsonpath='{.spec.ports[0].nodePort}')
[ "${SVC_NP}" = "${GATEWAY_NODEPORT}" ] || FAIL "Gateway Service nodePort is ${SVC_NP}, want ${GATEWAY_NODEPORT}"
[ "${TG_PORT}" = "${GATEWAY_NODEPORT}" ] || FAIL "target group port is ${TG_PORT}, want ${GATEWAY_NODEPORT}"
WORKER_SG=$(aws ec2 describe-security-groups --region "${AWS_REGION}" \
  --filters "Name=group-name,Values=${CLUSTER_NAME}-worker-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)
aws ec2 describe-security-group-rules --region "${AWS_REGION}" \
  --filters "Name=group-id,Values=${WORKER_SG}" \
  --query 'SecurityGroupRules[?IsEgress==`false`]' --output json | NLB_SG="${NLB_SG}" NP="${GATEWAY_NODEPORT}" python3 -c '
import json,sys,os
rules=json.load(sys.stdin)
np=int(os.environ["NP"]); nlb=os.environ["NLB_SG"]
assert any(r.get("FromPort")==np and r.get("ToPort")==np
           and (r.get("ReferencedGroupInfo") or {}).get("GroupId")==nlb for r in rules), \
  "no worker-SG rule for the NodePort from the NLB SG"
assert not any(r.get("FromPort")==30000 and r.get("ToPort")==32767 for r in rules), \
  "legacy 30000-32767 NodePort range rule still present"
' || FAIL "worker SG / NodePort coherence broken"
OK "port coherence: Service=${SVC_NP} · target group=${TG_PORT} · worker SG accepts it from the NLB SG only"

# 13d. NEGATIVE test: the NodePort must NOT answer from outside on ANY
# worker public IP — one closed door proves nothing about the other two.
W_PUB_IPS=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:Role,Values=worker" \
            "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text | tr '\t' '\n')
for W_PUB_IP in ${W_PUB_IPS}; do
  if curl -sk --max-time 6 "https://${W_PUB_IP}:${GATEWAY_NODEPORT}/" -o /dev/null 2>/dev/null; then
    FAIL "NodePort ${GATEWAY_NODEPORT} answers on worker public IP ${W_PUB_IP} — the SG should close it"
  fi
done
OK "negative proof: NodePort closed on EVERY worker public IP (NLB is the only application door)"

# 13e. POSITIVE e2e THROUGH the NLB: TLS pinned to the live Gateway cert.
# A 404 proves the full datapath only when Envoy identifies itself in the
# response. Refused, timeout, or an unmarked 404 is a failure. A real 200 is
# the application path: e2e con 200 real llega con las rutas de Repo 2.
GW_PIN=$(kubectl get secret -n infra shared-gw-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | base64)
E2E_HEADERS=$(mktemp)
# The whole chain, not just cleanup_pvc. Each stage above ADDS its cleanup to
# the trap; this line used to REPLACE it, silently dropping cleanup_iam,
# cleanup_netpol, cleanup_data, cleanup_contract and cleanup_backup_job. Every
# run that reached this far -- a full pass, or a failure in section 15 -- left
# those artefacts behind, and the next run died on AlreadyExists instead of
# testing anything. Built carefully in six places and overwritten in one.
trap 'rm -f "${E2E_HEADERS}"; cleanup_pvc; cleanup_iam; cleanup_netpol; cleanup_data; cleanup_contract; cleanup_backup_job' EXIT
E2E_CODE=$(curl -sk --max-time 20 --pinnedpubkey "sha256//${GW_PIN}" \
  --connect-to "shipments.logistics.lab:443:${NLB_DNS}:443" \
  -D "${E2E_HEADERS}" -o /dev/null -w '%{http_code}' "https://shipments.logistics.lab/") \
  || FAIL "TLS through the NLB was refused/timed out or failed certificate pinning"
envoy_e2e_verdict "${E2E_CODE}" "${E2E_HEADERS}" \
  || { sed 's/^/  /' "${E2E_HEADERS}" >&2; FAIL "HTTP ${E2E_CODE} is not an Envoy-attributable datapath response"; }
if [ "${E2E_CODE}" = 200 ]; then
  OK "e2e con 200 real llega con las rutas de Repo 2"
else
  OK "e2e through NLB: Envoy-attributable HTTP 404 (datapath complete; Repo 2 routes absent)"
fi

# ── 14. HA control plane — endpoint, quorum, single door (S2 piece 3) ────────
# Reuses NLB_ARN/NLB_DNS from section 13.

# 14a. 3 control-plane nodes, all Ready
CP_NODES=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers)
CP_TOTAL=$(echo "${CP_NODES}" | grep -c . || true)
CP_NOT_READY=$(echo "${CP_NODES}" | awk '$2 != "Ready" {n++} END {print n+0}')
[ "${CP_TOTAL}" -eq 3 ] || FAIL "expected 3 control-plane nodes, found ${CP_TOTAL}"
[ "${CP_NOT_READY}" -eq 0 ] || FAIL "${CP_NOT_READY} control-plane node(s) not Ready"
OK "3/3 control-plane nodes Ready"

# 14b. etcd: 3 members, ALL started (stacked etcd quorum). member list via
# one etcd pod with the standard kubeadm cert paths.
ETCD_POD=$(kubectl -n kube-system get pods -l component=etcd \
  --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}')
[ -n "${ETCD_POD}" ] || FAIL "no Running etcd pod found"
ETCD_MEMBERS=$(kubectl -n kube-system exec "${ETCD_POD}" -- etcdctl \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/server.crt \
  --key /etc/kubernetes/pki/etcd/server.key \
  member list -w json 2>/dev/null) || FAIL "etcdctl member list failed"
echo "${ETCD_MEMBERS}" | python3 -c '
import json,sys
m=json.load(sys.stdin)["members"]
started=[x for x in m if x.get("clientURLs")]
assert len(m)==3, f"expected 3 etcd members, found {len(m)}"
assert len(started)==3, f"only {len(started)}/3 etcd members started"
' || FAIL "etcd membership is not 3/3 started"
OK "etcd: 3/3 members started (stacked quorum)"

# 14c. API target group: exactly the 3 CP instance IDs, ALL healthy
API_TG_ARN=$(aws elbv2 describe-target-groups --names "${CLUSTER_NAME}-api-tg" --region "${AWS_REGION}" \
  --query 'TargetGroups[0].TargetGroupArn' --output text) || FAIL "API target group not found"
CP_IDS=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:Role,Values=control-plane" \
            "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n' | sort)
API_HEALTH_START=$(date +%s)
API_TARGETS_JSON='{"TargetHealthDescriptions":[]}'
until API_TARGETS_JSON=$("${TIMEOUT_BIN}" 15 aws elbv2 describe-target-health \
      --target-group-arn "${API_TG_ARN}" --region "${AWS_REGION}" \
      --cli-connect-timeout 5 --cli-read-timeout 10) \
  && [ "$(echo "${API_TARGETS_JSON}" | python3 -c '
import json,sys
t=json.load(sys.stdin)["TargetHealthDescriptions"]
print("ok" if len(t)==3 and all(d["TargetHealth"]["State"]=="healthy" for d in t) else "no")')" = "ok" ]; do
  API_HEALTH_ELAPSED=$(( $(date +%s) - API_HEALTH_START ))
  if [ "${API_HEALTH_ELAPSED}" -ge 300 ]; then
    echo "${API_TARGETS_JSON}" | python3 -c 'import json,sys; [print(" ", d["Target"]["Id"], d["TargetHealth"]["State"]) for d in json.load(sys.stdin)["TargetHealthDescriptions"]]' || true
    FAIL "API targets not 3/3 healthy after 300s"
  fi
  sleep 15
done
API_TARGET_IDS=$(echo "${API_TARGETS_JSON}" | python3 -c '
import json,sys
print("\n".join(sorted(d["Target"]["Id"] for d in json.load(sys.stdin)["TargetHealthDescriptions"])))')
[ "${API_TARGET_IDS}" = "${CP_IDS}" ] || FAIL "API target set differs from the CP instance set"
OK "API targets: exactly the 3 control planes, ALL healthy"

# 14d. NEGATIVE proof: :6443 must NOT answer on ANY CP public IP — the API
# is public THROUGH THE NLB ONLY (ADR-007); the CP SG accepts 6443 solely
# from the NLB's SG.
CP_PUB_IPS=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:Role,Values=control-plane" \
            "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text | tr '\t' '\n')
for CP_PUB_IP in ${CP_PUB_IPS}; do
  if curl -sk --max-time 6 "https://${CP_PUB_IP}:6443/" -o /dev/null 2>/dev/null; then
    FAIL "API :6443 answers on CP public IP ${CP_PUB_IP} — the SG should close it"
  fi
done
OK "negative proof: :6443 closed on EVERY CP public IP (NLB is the only API door)"

# 14e. Endpoint coherence: kubeconfig AND Cilium anchor to the NLB DNS —
# never to a node IP (a node can die; the endpoint cannot).
KC_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[ "${KC_SERVER}" = "https://${NLB_DNS}:6443" ] \
  || FAIL "kubeconfig server is ${KC_SERVER}, want https://${NLB_DNS}:6443"
# Cilium 1.19 does NOT keep k8sServiceHost in cilium-config: the chart
# injects it as KUBERNETES_SERVICE_HOST into the DaemonSet's containers
# (verified live 2026-08-16 — the ConfigMap has no such key at all).
# Assert BOTH the spec and the value inside the RUNNING agent: a spec
# updated without a rollout would otherwise read as compliant while the
# live agents still talked to the old endpoint.
CILIUM_HOST=$(kubectl -n kube-system get ds cilium -o json | python3 -c '
import json,sys
spec=json.load(sys.stdin)["spec"]["template"]["spec"]
for c in spec["containers"]:
    if c["name"] == "cilium-agent":
        for e in c.get("env", []):
            if e["name"] == "KUBERNETES_SERVICE_HOST":
                print(e.get("value", ""))
                break')
[ "${CILIUM_HOST}" = "${NLB_DNS}" ] \
  || FAIL "Cilium DaemonSet KUBERNETES_SERVICE_HOST is '${CILIUM_HOST}', want ${NLB_DNS}"
CILIUM_LIVE=$(kubectl -n kube-system exec ds/cilium -c cilium-agent -- printenv KUBERNETES_SERVICE_HOST 2>/dev/null | tr -d '\r')
[ "${CILIUM_LIVE}" = "${NLB_DNS}" ] \
  || FAIL "the RUNNING cilium-agent points at '${CILIUM_LIVE}', want ${NLB_DNS} (DaemonSet updated without a rollout?)"
# IAM auth path: the authenticator DaemonSet must cover all 3 CPs (the API
# server on EVERY CP webhooks to ITS OWN local authenticator).
AUTH_DS=$(kubectl -n kube-system get ds aws-iam-authenticator \
  -o jsonpath='{.status.desiredNumberScheduled} {.status.numberReady}')
[ "${AUTH_DS}" = "3 3" ] || FAIL "aws-iam-authenticator DaemonSet is ${AUTH_DS}, want 3 3"
OK "endpoint coherence: kubeconfig + Cilium on the NLB DNS · authenticator 3/3"

# ── 15. Out-of-band access — the channel recovery depends on (INCIDENTS #16) ─
# This section exists because a documented recovery procedure was found to
# depend on an access nobody had ever exercised. A door never opened is
# indistinguishable from a locked one, so it gets opened on EVERY apply.

# 15a. SSM's view of the fleet must be EXACTLY the cluster's instances.
CLUSTER_IDS=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n' | sort)
CLUSTER_COUNT=$(echo "${CLUSTER_IDS}" | grep -c . || true)
SSM_IDS=$(aws ssm describe-instance-information --region "${AWS_REGION}" \
  --query 'InstanceInformationList[].InstanceId' --output text | tr '\t' '\n' | sort)
SSM_ONLINE=$(aws ssm describe-instance-information --region "${AWS_REGION}" \
  --query 'InstanceInformationList[?PingStatus==`Online`].InstanceId' --output text | tr '\t' '\n' | sort)
[ "${SSM_IDS}" = "${CLUSTER_IDS}" ] || FAIL "SSM inventory != cluster instances
  SSM:     ${SSM_IDS//$'\n'/ }
  cluster: ${CLUSTER_IDS//$'\n'/ }"
[ "${SSM_ONLINE}" = "${CLUSTER_IDS}" ] || FAIL "not every node is Online in SSM
  online:  ${SSM_ONLINE//$'\n'/ }
  cluster: ${CLUSTER_IDS//$'\n'/ }"
OK "SSM inventory: exactly the ${CLUSTER_COUNT} cluster nodes, all Online"

# 15b. Online is a heartbeat, not proof of access: deliver and RUN something
# on every node and demand the exact output back.
. "$(dirname "$0")/lib/ssm-exec.sh"
for IID in ${CLUSTER_IDS}; do
  ssm_canary "${IID}" || FAIL "out-of-band canary FAILED on ${IID} — recovery would be impossible"
done
OK "canary Run Command executed on all ${CLUSTER_COUNT} nodes (exact output, as root)"

# 15c. NEGATIVE proof: inbound SSH must not exist on either security group.
for SG_NAME in "${CLUSTER_NAME}-cp-sg" "${CLUSTER_NAME}-worker-sg"; do
  SG_ID=$(aws ec2 describe-security-groups --region "${AWS_REGION}" \
    --filters "Name=group-name,Values=${SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text)
  SSH_RULES=$(aws ec2 describe-security-group-rules --region "${AWS_REGION}" \
    --filters "Name=group-id,Values=${SG_ID}" \
    --query 'length(SecurityGroupRules[?IsEgress==`false` && FromPort==`22`])' --output text)
  [ "${SSH_RULES}" = "0" ] || FAIL "${SG_NAME} still has ${SSH_RULES} inbound SSH rule(s) — the port was meant to be closed"
done
OK "negative proof: no inbound TCP/22 on either security group"

# 15d. The HUMAN channel. Closing SSH without ever proving the interactive
# door opens would repeat the very mistake this section exists to prevent, one
# level up -- so this is exercised locally, by an operator, with the role that
# is meant to open it.
#
# The boundary is CI-vs-local, declared from the environment. It used to be
# "does the operator have session-manager-plugin", on the premise that CI
# runners do not -- a premise that stopped being true. The runners now carry
# the plugin, the guard stopped skipping, and the check failed on the
# ssm:StartSession the CI role lacks BY DESIGN: 64 green checks and one red
# that could not have been anything else.
#
# Not guarded on "does this principal have StartSession" either: asking that
# needs another capability, and it would turn a REAL AccessDenied -- an actual
# local regression -- into a silent skip.
if [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
  echo "  . human channel not exercised in CI; the CI role intentionally lacks ssm:StartSession"
elif command -v session-manager-plugin >/dev/null 2>&1; then
  FIRST_CP=$(aws ec2 describe-instances --region "${AWS_REGION}" \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
              "Name=tag:CPIndex,Values=0" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  SESSION_OUT=$({ printf 'hostname\n'; sleep 6; printf 'exit\n'; sleep 2; } \
    | aws ssm start-session --target "${FIRST_CP}" --region "${AWS_REGION}" 2>&1 || true)
  echo "${SESSION_OUT}" | grep -q "Starting session with SessionId" \
    || FAIL "interactive Session Manager shell did not open on ${FIRST_CP}"
  echo "${SESSION_OUT}" | grep -qE "^ip-10-" \
    || FAIL "interactive shell opened but did not execute a command"
  OK "human channel: interactive shell opened on CP-0 and ran a command (make ssm-cp works)"
else
  echo "  . human channel not exercised locally: session-manager-plugin unavailable"
fi

echo ""
echo "✓ Smoke test passed — ${CHECKS_OK} checks OK: cluster, platform, IAM, network, data, registry, app contract, backups, NLB entry, HA control plane and out-of-band access are healthy"
