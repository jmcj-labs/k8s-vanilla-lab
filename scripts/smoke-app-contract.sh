#!/usr/bin/env bash
# App-contract smoke — runs with PLATFORM identity AFTER Repo 2 has deployed
# (the coronation, not the Apply: a freshly-created cluster has no app yet).
#
# Verifies the app is actually running against the contract this repo set up:
#   1. Prometheus targets for the four services up==1 with samples.
#   2. Real ECR pull per pod (the criterion reserved from 3a): each pod Ready,
#      references the expected ECR repo, tag exactly ${GITHUB_SHA}, imageID a
#      digest from ECR — not mere existence.
#
# Env: GITHUB_SHA (required — the tag the app was deployed with),
#      AWS_REGION, CLUSTER_NAME. KUBECONFIG must point at the cluster.
set -euo pipefail

FAIL() { echo "✗ $*" >&2; exit 1; }
OK()   { echo "✓ $*"; }

: "${GITHUB_SHA:?set GITHUB_SHA to the deployed image tag}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
SERVICES="shipments-api routing tracking-events traffic-generator"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_HOST="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
PROM="http://kube-prometheus-stack-prometheus.infra.svc.cluster.local:9090"

prom_count() {
  kubectl -n infra run "smoke-appq-$$-${RANDOM}" --rm -i --restart=Never --image=busybox:1.36 -- \
    sh -c "wget -qO- '${PROM}/api/v1/query?query=$1'" 2>/dev/null \
    | grep -o '{.*}' \
    | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)["data"]["result"]))
except Exception: print(0)' 2>/dev/null || echo 0
}

echo "== App-contract smoke (tag ${GITHUB_SHA}) =="

for SVC in ${SERVICES}; do
  # Pods present and Ready
  PODS=$(kubectl -n logistics get pods -l "app.kubernetes.io/name=${SVC}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  [ -n "${PODS}" ] || FAIL "${SVC}: no pods in logistics"
  while read -r POD; do
    [ -n "${POD}" ] || continue
    READY=$(kubectl -n logistics get pod "${POD}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    [ "${READY}" = "True" ] || FAIL "${SVC}: pod ${POD} not Ready"
    # image reference: expected ECR repo + exactly the SHA tag
    IMG=$(kubectl -n logistics get pod "${POD}" \
      -o jsonpath="{.spec.containers[?(@.name=='${SVC}')].image}")
    [ -n "${IMG}" ] || IMG=$(kubectl -n logistics get pod "${POD}" -o jsonpath='{.spec.containers[0].image}')
    [ "${IMG}" = "${ECR_HOST}/${SVC}:${GITHUB_SHA}" ] \
      || FAIL "${SVC}: image is '${IMG}', expected '${ECR_HOST}/${SVC}:${GITHUB_SHA}'"
    # imageID must be a digest resolved from ECR (real pull, not name only)
    IMGID=$(kubectl -n logistics get pod "${POD}" \
      -o jsonpath='{.status.containerStatuses[0].imageID}')
    echo "${IMGID}" | grep -q "${ECR_HOST}/${SVC}@sha256:" \
      || FAIL "${SVC}: imageID '${IMGID}' is not an ECR digest (image not really pulled from ECR)"
  done <<< "${PODS}"
  OK "${SVC}: pods Ready, image ${SVC}:${GITHUB_SHA}, pulled from ECR by digest"
done

# Prometheus scrapes each service (up==1) with samples
for SVC in ${SERVICES}; do
  N=0
  for _ in $(seq 1 20); do
    N=$(prom_count "up{namespace=\"logistics\",pod=~\"${SVC}.*\"}==1")
    [ "${N:-0}" -gt 0 ] && break
    sleep 6
  done
  [ "${N:-0}" -gt 0 ] || FAIL "${SVC}: no Prometheus target up==1 after ~2min"
  OK "${SVC}: Prometheus target up==1"
done

echo ""
echo "✓ App contract satisfied: 4 services Ready, pulled from ECR by SHA digest, scraped by Prometheus"
