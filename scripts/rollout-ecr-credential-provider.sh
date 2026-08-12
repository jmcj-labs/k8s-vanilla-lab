#!/usr/bin/env bash
# Reentrant rollout of the ECR credential provider onto LIVE workers.
#
# cloud-init is first-boot only, so existing workers never pick up the
# bootstrap change (bootstrap/worker.yaml handles FUTURE workers). This
# installs the binary + config and extends KUBELET_EXTRA_ARGS on each
# running worker, ONE AT A TIME, with health gates and per-node rollback.
#
# Kubernetes-native (no SSH): a privileged one-shot Job per node enters the
# host mount+PID namespace via nsenter. Works identically from a CI runner
# (which cannot SSH — port 22 is restricted to my_ip) and from a laptop —
# only kubectl against the break-glass kubeconfig is required.
#
# The kubelet restart must NOT evict workloads or restart containerd — no
# drain. It reads a running-config change; static pods and CNI stay put.
set -euo pipefail

NODE_READY_TIMEOUT=180
JOB_TIMEOUT=180

ECR_CP_VERSION="v1.36.1"
ECR_CP_SHA256="59a6fc141dc08cd0661d885d2cf8993df42f62cc2bd7a08902dde63f47e0b384"
ECR_CP_URL="https://storage.googleapis.com/k8s-staging-provider-aws/releases/${ECR_CP_VERSION}/linux/amd64/ecr-credential-provider-linux-amd64"

log()  { echo "[$(date +'%H:%M:%S')] $*"; }
FAIL() { echo "✗ $*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || FAIL "kubectl not found"

data_healthy() {
  local pg kafka
  pg=$(kubectl -n data get cluster logistics-pg -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
  [ "${pg}" = "Cluster in healthy state" ] || { echo "  PG: ${pg}"; return 1; }
  kafka=$(kubectl -n data get kafka logistics-kafka \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
  [ "${kafka}" = "True" ] || { echo "  Kafka Ready: ${kafka}"; return 1; }
  return 0
}

node_ready() {
  [ "$(kubectl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

# Runs a privileged one-shot Job pinned to $1, executing the given ACTION
# (install | rollback) inside the host namespaces via nsenter. Returns the
# Job's exit status.
run_node_job() {
  local node="$1" action="$2"; local job="ecr-cp-$2-${1##*-}"
  kubectl -n kube-system delete job "${job}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl -n kube-system apply -f - >/dev/null <<JOB
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  labels: {app.kubernetes.io/part-of: k8s-vanilla-lab-rollout}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: Never
      hostPID: true
      nodeName: ${node}
      tolerations: [{operator: Exists}]
      containers:
        - name: rollout
          image: public.ecr.aws/docker/library/busybox:1.36
          securityContext: {privileged: true}
          env:
            - {name: ACTION, value: "${action}"}
            - {name: URL, value: "${ECR_CP_URL}"}
            - {name: SHA, value: "${ECR_CP_SHA256}"}
          command: ["nsenter", "--target", "1", "--mount", "--uts", "--ipc", "--net", "--pid", "--", "bash", "-euo", "pipefail", "-c"]
          args:
            - |
              DIR=/etc/kubernetes/image-credential-provider
              if [ "\$ACTION" = rollback ]; then
                [ -f /etc/default/kubelet.bak-ecr ] && cp -f /etc/default/kubelet.bak-ecr /etc/default/kubelet
                systemctl restart kubelet
                exit 0
              fi
              cp -f /etc/default/kubelet /etc/default/kubelet.bak-ecr
              mkdir -p "\$DIR"
              curl -fsSL -o /tmp/ecr-cp "\$URL"
              echo "\$SHA  /tmp/ecr-cp" | sha256sum -c -
              install -m 0755 /tmp/ecr-cp "\$DIR/ecr-credential-provider"; rm -f /tmp/ecr-cp
              cat > "\$DIR/config.yaml" <<'CFG'
              apiVersion: kubelet.config.k8s.io/v1
              kind: CredentialProviderConfig
              providers:
                - name: ecr-credential-provider
                  matchImages: ["*.dkr.ecr.*.amazonaws.com"]
                  defaultCacheDuration: "12h"
                  apiVersion: credentialprovider.kubelet.k8s.io/v1
              CFG
              if ! grep -q image-credential-provider-config /etc/default/kubelet; then
                sed -i "s|^KUBELET_EXTRA_ARGS=\(.*\)\$|KUBELET_EXTRA_ARGS=\1 --image-credential-provider-config=\$DIR/config.yaml --image-credential-provider-bin-dir=\$DIR|" /etc/default/kubelet
              fi
              grep -q provider-id /etc/default/kubelet || { echo "provider-id lost"; exit 1; }
              systemctl restart kubelet
JOB
  kubectl -n kube-system wait --for=condition=Complete "job/${job}" --timeout="${JOB_TIMEOUT}s" >/dev/null 2>&1
}

log "Pre-flight: whole cluster health"
data_healthy || FAIL "data layer not healthy before rollout — refusing to start"

for NODE in $(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
                -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  [ -n "${NODE}" ] || continue

  # Idempotent skip via a node-label marker (the kubelet FLAG does not
  # appear in configz — that only exposes the KubeletConfiguration object).
  if [ "$(kubectl get node "${NODE}" -o jsonpath='{.metadata.labels.k8s-vanilla-lab/ecr-cp}' 2>/dev/null)" = "${ECR_CP_VERSION}" ]; then
    log "── ${NODE}: already configured (${ECR_CP_VERSION}) — skipping"
    continue
  fi

  log "── ${NODE}: installing ──"
  node_ready "${NODE}" || FAIL "${NODE} not Ready before rollout — aborting"

  if ! run_node_job "${NODE}" install; then
    log "  install job failed — rolling back ${NODE}"
    run_node_job "${NODE}" rollback || true
    FAIL "install failed on ${NODE}; rolled back, stopping rollout"
  fi

  READY=""
  for _ in $(seq 1 $((NODE_READY_TIMEOUT / 5))); do
    sleep 5
    node_ready "${NODE}" && { READY=yes; break; }
  done
  [ -n "${READY}" ] || { run_node_job "${NODE}" rollback || true; FAIL "${NODE} not Ready after kubelet restart; rolled back, stopping"; }

  if ! data_healthy; then
    log "  data degraded after ${NODE} — rolling back"
    run_node_job "${NODE}" rollback || true
    FAIL "data layer degraded after ${NODE}; rolled back, stopping"
  fi
  kubectl label node "${NODE}" "k8s-vanilla-lab/ecr-cp=${ECR_CP_VERSION}" --overwrite >/dev/null
  log "  ✓ ${NODE}: provider installed, Ready, data healthy"
done

log "✓ ECR credential provider rolled out to all workers"
