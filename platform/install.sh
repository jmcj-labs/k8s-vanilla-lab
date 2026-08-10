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
MANIFESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/manifests" && pwd)"

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

log "Step 1/8: Adding Helm repositories"
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null
helm repo add strimzi https://strimzi.io/charts/ >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null
log "✓ Helm repositories ready"

log "Step 2/8: Namespaces (infra, data, logistics) + StorageClass gp3"
kubectl apply -f "${MANIFESTS}/namespaces.yaml"
kubectl apply -f "${MANIFESTS}/storageclass-gp3.yaml"
log "✓ Namespaces and default gp3 StorageClass applied"

log "Step 3/8: EBS CSI driver (chart ${EBS_CSI_CHART_VERSION})"
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

log "Step 4/8: cert-manager (chart ${CERT_MANAGER_CHART_VERSION}) + selfsigned ClusterIssuer"
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

log "Step 5/8: Shared Gateway (cilium class, HTTPS *.logistics.lab)"
# The 'cilium' GatewayClass is created by the cilium-operator at startup
# (gatewayAPI.enabled=true in the bootstrap Helm install).
kubectl wait --for=condition=Accepted gatewayclass/cilium --timeout=180s
kubectl apply -f "${MANIFESTS}/gateway-shared.yaml"
log "✓ Gateway infra/shared-gw applied"

log "Step 6/8: CloudNativePG operator (chart ${CNPG_CHART_VERSION})"
ensure_clean_release data cnpg
# Operator only — PostgreSQL clusters are application-owned, not platform-owned.
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace data \
  --version "${CNPG_CHART_VERSION}" \
  --wait --timeout 5m
log "✓ CloudNativePG operator installed"

log "Step 7/8: Strimzi Kafka operator (chart ${STRIMZI_CHART_VERSION})"
ensure_clean_release data strimzi
# Operator only — Kafka clusters are application-owned, not platform-owned.
helm upgrade --install strimzi strimzi/strimzi-kafka-operator \
  --namespace data \
  --version "${STRIMZI_CHART_VERSION}" \
  --wait --timeout 5m
log "✓ Strimzi operator installed"

log "Step 8/8: kube-prometheus-stack (chart ${KUBE_PROM_STACK_CHART_VERSION})"
ensure_clean_release infra kube-prometheus-stack
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace infra \
  --version "${KUBE_PROM_STACK_CHART_VERSION}" \
  --set grafana.service.type=NodePort \
  --set alertmanager.enabled=false \
  --wait --timeout 10m
log "✓ kube-prometheus-stack installed"

log "=== Platform layer installed successfully ==="
log "Grafana NodePort: kubectl -n infra get svc kube-prometheus-stack-grafana"
