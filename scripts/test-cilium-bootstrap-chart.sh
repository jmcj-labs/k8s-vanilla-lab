#!/usr/bin/env bash
set -euo pipefail

command -v helm >/dev/null 2>&1 || { echo "ERROR helm is required" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
helm repo add cilium-bootstrap-test https://helm.cilium.io --force-update >/dev/null
helm template cilium cilium-bootstrap-test/cilium \
  --namespace kube-system --version 1.20.1 \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=api.example.invalid \
  --set k8sServicePort=6443 \
  --set gatewayAPI.enabled=true \
  --set gatewayAPI.externalTrafficPolicy=Cluster \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true > "$TMP/rendered.yaml"
grep -q 'quay.io/cilium/cilium:v1.20.1' "$TMP/rendered.yaml"
grep -q 'KUBERNETES_SERVICE_HOST' "$TMP/rendered.yaml"
grep -q 'api.example.invalid' "$TMP/rendered.yaml"
echo "OK official Cilium 1.20.1 chart renders the exact bootstrap values"
