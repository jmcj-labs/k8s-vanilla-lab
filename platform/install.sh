#!/usr/bin/env bash
# Platform layer installer for k8s-vanilla-lab
#
# Idempotent by construction (helm upgrade --install + kubectl apply): safe to
# re-run at any time. Executed via `make platform` against the kubeconfig
# fetched from SSM — locally after `make apply`, or from the CI apply workflow.
#
# Why not from the control-plane cloud-init? See platform/README.md
# ("Execution model").

set -euo pipefail

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

AWS_REGION="${AWS_REGION:-eu-west-1}"
CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
MANIFESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/manifests" && pwd)"
ACCESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/access" && pwd)"

# Pinned chart versions (keep in sync with platform/README.md)
EBS_CSI_CHART_VERSION="2.63.1"          # app v1.63.1
CERT_MANAGER_CHART_VERSION="v1.21.1"    # app v1.21.1
CNPG_CHART_VERSION="0.29.0"             # operator 1.30.0
STRIMZI_CHART_VERSION="1.1.0"           # operator 1.1.0
KUBE_PROM_STACK_CHART_VERSION="88.2.0"  # prometheus-operator v0.93.0

command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl not found" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "✗ helm not found" >&2; exit 1; }
# Retry briefly: right after bootstrap the API can take a few seconds to
# accept external connections (EIP path, SG propagation).
ELAPSED=0
until kubectl version >/dev/null 2>&1; do
  if [ "${ELAPSED}" -ge 120 ]; then
    echo "✗ Cluster unreachable after ${ELAPSED}s — set KUBECONFIG (make kubeconfig) and retry" >&2
    exit 1
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

# A release left in pending-* (concurrent run, killed job) or failed with no
# deployed revision (first install timed out) cannot be upgraded — uninstall
# it so the following `helm upgrade --install` starts clean. Makes the script
# re-entrant after a failed or interrupted run.
ensure_clean_release() {
  local ns="$1" rel="$2" status deployed
  status=$(helm status -n "${ns}" "${rel}" -o json 2>/dev/null | jq -r '.info.status' || echo "absent")
  case "${status}" in
    pending-install|pending-upgrade|pending-rollback)
      log "⚠ Release ${ns}/${rel} stuck in ${status} — uninstalling for a clean retry"
      helm uninstall -n "${ns}" "${rel}" --wait --timeout 3m || true
      ;;
    failed)
      deployed=$(helm history -n "${ns}" "${rel}" -o json 2>/dev/null \
        | jq '[.[] | select(.status=="deployed" or .status=="superseded")] | length' || echo 0)
      if [ "${deployed}" -eq 0 ]; then
        log "⚠ Release ${ns}/${rel} failed with no deployed revision — uninstalling for a clean retry"
        helm uninstall -n "${ns}" "${rel}" --wait --timeout 3m || true
      fi
      ;;
  esac
}

log "=== Installing platform layer (region: ${AWS_REGION}) ==="

log "Step 1/11: Adding Helm repositories"
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null
helm repo add strimzi https://strimzi.io/charts/ >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null
log "✓ Helm repositories ready"

log "Step 2/11: Namespaces (infra, data, logistics) + StorageClass gp3"
kubectl apply -f "${MANIFESTS}/namespaces.yaml"
kubectl apply -f "${MANIFESTS}/storageclass-gp3.yaml"
log "✓ Namespaces and default gp3 StorageClass applied"

log "Step 2b/11: IAM access — authenticator mappings, RBAC and DaemonSet"
# Rendered from the single source of truth (profiles.yaml, ADR-005 decision 4).
# The bootstrap already placed the webhook material on the CP; everything
# reentrant lives here: mappings ConfigMap (DynamicFile), RBAC, DaemonSet.
command -v yq >/dev/null 2>&1 || { echo "✗ yq not found (needed to render access profiles)" >&2; exit 1; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ACCOUNT_ID
# Same clusterID as bootstrap and Makefile: ACCOUNT.REGION.NAME
CLUSTER_ID="${ACCOUNT_ID}.${AWS_REGION}.${CLUSTER_NAME}"

ACCESS_RENDER=$(mktemp -d)
trap 'rm -rf "${ACCESS_RENDER}"' EXIT

# Server config: DynamicFile has no CLI flag in v0.7.18 — backend mode and
# file path only exist as config-file keys.
cat > "${ACCESS_RENDER}/config.yaml" <<AUTHCFG
clusterID: ${CLUSTER_ID}
server:
  backendmode:
    - DynamicFile
  dynamicfilepath: /etc/aws-iam-authenticator/dynamic-mappings.json
AUTHCFG

# DynamicFile mappings (JSON): one mapRoles entry per profile.
# username carries {{SessionName}} — with --forward-session-name on the
# client, audit lines show WHO assumed the role, not just the role.
yq -o=json '{
  "mapRoles": [.accessProfiles[] | {
    "rolearn": ("arn:aws:iam::" + strenv(ACCOUNT_ID) + ":role/" + .iamRoleName),
    "username": (.name + ":{{SessionName}}"),
    "groups": .kubernetesGroups
  }],
  "mapUsers": [],
  "mapAccounts": []
}' "${ACCESS}/profiles.yaml" > "${ACCESS_RENDER}/dynamic-mappings.json"

kubectl -n kube-system create configmap aws-iam-authenticator \
  --from-file=config.yaml="${ACCESS_RENDER}/config.yaml" \
  --from-file=dynamic-mappings.json="${ACCESS_RENDER}/dynamic-mappings.json" \
  --dry-run=client -o yaml | kubectl apply -f -

# RBAC: the developer ClusterRole is static; bindings are rendered per profile.
kubectl apply -f "${ACCESS}/clusterrole-developer.yaml"

PROFILE_COUNT=$(yq '.accessProfiles | length' "${ACCESS}/profiles.yaml")
for i in $(seq 0 $((PROFILE_COUNT - 1))); do
  P_NAME=$(yq -r ".accessProfiles[${i}].name" "${ACCESS}/profiles.yaml")
  P_RBAC=$(yq -r ".accessProfiles[${i}].rbacProfile" "${ACCESS}/profiles.yaml")
  P_GROUPS=$(yq -r ".accessProfiles[${i}].kubernetesGroups[]" "${ACCESS}/profiles.yaml")

  if [ "${P_RBAC}" = "cluster-admin" ]; then
    # Built-in ClusterRole on purpose: revocable binding, no local wildcard
    # copy — the dangerous thing is system:masters, not cluster-admin.
    for GRP in ${P_GROUPS}; do
      kubectl apply -f - <<BINDING
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: access-${P_NAME}-${GRP}
  labels:
    app.kubernetes.io/part-of: k8s-vanilla-lab-access
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: ${GRP}
BINDING
    done
  else
    P_NAMESPACES=$(yq -r ".accessProfiles[${i}].namespaces[]" "${ACCESS}/profiles.yaml")
    for NS in ${P_NAMESPACES}; do
      for GRP in ${P_GROUPS}; do
        kubectl apply -f - <<BINDING
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: access-${P_NAME}-${GRP}
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: k8s-vanilla-lab-access
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${P_RBAC}
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: ${GRP}
BINDING
      done
    done
  fi
done

kubectl apply -f "${ACCESS}/daemonset.yaml"
kubectl -n kube-system rollout status ds/aws-iam-authenticator --timeout=180s
log "✓ IAM access ready (DynamicFile mappings, RBAC, authenticator DaemonSet)"

log "Step 3/11: EBS CSI driver (chart ${EBS_CSI_CHART_VERSION})"
ensure_clean_release kube-system aws-ebs-csi-driver
# controller.region is set explicitly: IMDS is not reachable from the pod
# network even with hop limit 2 (see docs/INCIDENTS.md #4), so the controller
# must not depend on instance metadata for region discovery.
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --version "${EBS_CSI_CHART_VERSION}" \
  --set "controller.region=${AWS_REGION}" \
  --wait --timeout 5m
log "✓ EBS CSI driver installed"

log "Step 4/11: cert-manager (chart ${CERT_MANAGER_CHART_VERSION}) + selfsigned ClusterIssuer"
ensure_clean_release infra cert-manager
# --enable-gateway-api activates the gateway-shim controller that resolves
# the cert-manager.io/cluster-issuer annotation on Gateway resources.
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace infra \
  --version "${CERT_MANAGER_CHART_VERSION}" \
  --set crds.enabled=true \
  --set "extraArgs={--enable-gateway-api}" \
  --wait --timeout 5m
kubectl apply -f "${MANIFESTS}/clusterissuer-selfsigned.yaml"
log "✓ cert-manager installed, ClusterIssuer 'selfsigned' applied"

log "Step 5/11: Shared Gateway (cilium class, HTTPS *.logistics.lab)"
# The 'cilium' GatewayClass is created by the cilium-operator at startup
# (gatewayAPI.enabled=true in the bootstrap Helm install).
kubectl wait --for=condition=Accepted gatewayclass/cilium --timeout=180s
# LB-IPAM pool first: without it the Gateway's LoadBalancer Service never
# gets an address (no cloud LB controller) and Programmed stays False.
kubectl apply -f "${MANIFESTS}/lb-ipam-pool.yaml"
kubectl apply -f "${MANIFESTS}/gateway-shared.yaml"
log "✓ Gateway infra/shared-gw applied (LB IP from Cilium LB-IPAM; external access via NodePort)"

log "Step 6/11: CloudNativePG operator (chart ${CNPG_CHART_VERSION})"
ensure_clean_release data cnpg
# Operator only — PostgreSQL clusters are application-owned, not platform-owned.
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace data \
  --version "${CNPG_CHART_VERSION}" \
  --wait --timeout 5m
log "✓ CloudNativePG operator installed"

log "Step 7/11: Strimzi Kafka operator (chart ${STRIMZI_CHART_VERSION})"
ensure_clean_release data strimzi
# Operator only — Kafka clusters are application-owned, not platform-owned.
helm upgrade --install strimzi strimzi/strimzi-kafka-operator \
  --namespace data \
  --version "${STRIMZI_CHART_VERSION}" \
  --wait --timeout 5m
log "✓ Strimzi operator installed"

log "Step 8/11: kube-prometheus-stack (chart ${KUBE_PROM_STACK_CHART_VERSION})"
ensure_clean_release infra kube-prometheus-stack
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace infra \
  --version "${KUBE_PROM_STACK_CHART_VERSION}" \
  --set grafana.service.type=NodePort \
  --set alertmanager.enabled=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout 10m
log "✓ kube-prometheus-stack installed"

log "Step 9/11: Cilium network policies (IMDS deny + logistics default-deny)"
# Applied last: everything above must be able to install without them, and
# the deny-IMDS exception (EBS CSI) is verified by the smoke right after.
# The data-namespace policy is deliberately DEFERRED to phase 2: today it
# holds the CNPG/Strimzi operators (which talk to the API server) and the
# operand replication ports do not exist yet.
POLICIES="$(cd "$(dirname "${BASH_SOURCE[0]}")/policies" && pwd)"
kubectl apply -f "${POLICIES}/ccnp-deny-imds.yaml"
kubectl apply -f "${POLICIES}/cnp-logistics-default-deny.yaml"
log "✓ Network policies applied (deny IMDS except EBS CSI; logistics default-deny)"

log "Step 10/11: Data layer — PostgreSQL (CNPG x3) + Kafka (Strimzi KRaft x3)"
DATA="$(cd "$(dirname "${BASH_SOURCE[0]}")/data" && pwd)"
kubectl apply -f "${DATA}/cnpg-cluster.yaml"
kubectl apply -f "${DATA}/kafka-cluster.yaml"
# Wait for BOTH clusters to be healthy BEFORE their network policies land
# (phase-2 brief: never debug bootstrap and policy at the same time).
kubectl -n data wait cluster/logistics-pg \
  --for=jsonpath='{.status.phase}'='Cluster in healthy state' --timeout=600s
kubectl -n data wait kafka/logistics-kafka --for=condition=Ready --timeout=600s
log "✓ Data layer healthy (PG primary+2 sync replicas; Kafka 3 KRaft nodes)"

log "Step 11/11: Data-namespace network policies (operand-scoped)"
# By operand labels, not the whole namespace: the operators stay free.
kubectl apply -f "${POLICIES}/cnp-data-postgres.yaml"
kubectl apply -f "${POLICIES}/cnp-data-kafka.yaml"
log "✓ Data network policies applied (PG + Kafka operands, default-deny with openings)"

log "=== Platform layer installed successfully ==="
log "Grafana NodePort: kubectl -n infra get svc kube-prometheus-stack-grafana"
