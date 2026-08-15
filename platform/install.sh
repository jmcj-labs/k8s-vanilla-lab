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
command -v aws >/dev/null 2>&1 || { echo "✗ aws CLI not found (needed for backup credentials)" >&2; exit 1; }

# Persistent backups bucket (tofu/envs/persistent). Same derivation as both
# tofu stacks so nobody has to pass it explicitly.
BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/backup" && pwd)"
if [ -z "${BACKUP_BUCKET:-}" ]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  BACKUP_BUCKET="${CLUSTER_NAME}-backups-${ACCOUNT_ID}"
fi
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

log "Step 1/12: Adding Helm repositories"
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null
helm repo add strimzi https://strimzi.io/charts/ >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null
log "✓ Helm repositories ready"

log "Step 2/12: Namespaces (infra, data, logistics) + StorageClass gp3"
kubectl apply -f "${MANIFESTS}/namespaces.yaml"
kubectl apply -f "${MANIFESTS}/storageclass-gp3.yaml"
log "✓ Namespaces and default gp3 StorageClass applied"

log "Step 2b/12: IAM access — authenticator mappings, RBAC and DaemonSet"
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

log "Step 3/12: EBS CSI driver (chart ${EBS_CSI_CHART_VERSION})"
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

log "Step 4/12: cert-manager (chart ${CERT_MANAGER_CHART_VERSION}) + selfsigned ClusterIssuer"
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

log "Step 5/12: Shared Gateway (cilium class, HTTPS *.logistics.lab)"
# The 'cilium' GatewayClass is created by the cilium-operator at startup
# (gatewayAPI.enabled=true in the bootstrap Helm install).
kubectl wait --for=condition=Accepted gatewayclass/cilium --timeout=180s
# LB-IPAM pool first: without it the Gateway's LoadBalancer Service never
# gets an address (no cloud LB controller) and Programmed stays False.
kubectl apply -f "${MANIFESTS}/lb-ipam-pool.yaml"
kubectl apply -f "${MANIFESTS}/gateway-shared.yaml"
log "✓ Gateway infra/shared-gw applied (LB IP from Cilium LB-IPAM; external access via NodePort)"

log "Step 6/12: CloudNativePG operator (chart ${CNPG_CHART_VERSION})"
ensure_clean_release data cnpg
# Operator only — PostgreSQL clusters are application-owned, not platform-owned.
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace data \
  --version "${CNPG_CHART_VERSION}" \
  --wait --timeout 5m
log "✓ CloudNativePG operator installed"

log "Step 7/12: Strimzi Kafka operator (chart ${STRIMZI_CHART_VERSION})"
ensure_clean_release data strimzi
# Operator only — Kafka clusters are application-owned, not platform-owned.
helm upgrade --install strimzi strimzi/strimzi-kafka-operator \
  --namespace data \
  --version "${STRIMZI_CHART_VERSION}" \
  --wait --timeout 5m
log "✓ Strimzi operator installed"

log "Step 8/12: kube-prometheus-stack (chart ${KUBE_PROM_STACK_CHART_VERSION})"
ensure_clean_release infra kube-prometheus-stack
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace infra \
  --version "${KUBE_PROM_STACK_CHART_VERSION}" \
  --set grafana.service.type=NodePort \
  --set alertmanager.enabled=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout 10m
log "✓ kube-prometheus-stack installed"

log "Step 9/12: Cilium network policies (IMDS deny + logistics default-deny)"
# Applied last: everything above must be able to install without them, and
# the deny-IMDS exception (EBS CSI) is verified by the smoke right after.
# The data-namespace policy is deliberately DEFERRED to phase 2: today it
# holds the CNPG/Strimzi operators (which talk to the API server) and the
# operand replication ports do not exist yet.
POLICIES="$(cd "$(dirname "${BASH_SOURCE[0]}")/policies" && pwd)"
kubectl apply -f "${POLICIES}/ccnp-deny-imds.yaml"
kubectl apply -f "${POLICIES}/cnp-logistics-default-deny.yaml"
log "✓ Network policies applied (deny IMDS except EBS CSI; logistics default-deny)"

log "Step 9b/12: CNPG backup credentials (SSM → data/cnpg-backup-creds, reentrant)"
# Deposited ONCE by the operator under /k8s/persistent/ — a prefix the
# cluster's destroy-time SSM cleanup (which wipes /k8s/<cluster_name>) never
# touches, while staying inside the parameter/k8s/* scope the CI role has.
# See tofu/envs/persistent/README.md. Values never printed / no temp files.
SSM_KEYS_PARAM="/k8s/persistent/${CLUSTER_NAME}/cnpg-backup-keys"
if ! aws ssm get-parameter --name "${SSM_KEYS_PARAM}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "✗ ${SSM_KEYS_PARAM} not found in SSM — deposit the barman access keys" >&2
  echo "  once (manual, local): see tofu/envs/persistent/README.md" >&2
  exit 1
fi
aws ssm get-parameter --name "${SSM_KEYS_PARAM}" --with-decryption \
  --query Parameter.Value --output text --region "${AWS_REGION}" \
  | python3 -c '
import json,sys
keys=json.load(sys.stdin)
json.dump({"apiVersion":"v1","kind":"Secret",
     "metadata":{"name":"cnpg-backup-creds","namespace":"data",
                 "labels":{"cnpg.io/reload":"true"}},
     "type":"Opaque",
     "stringData":{"ACCESS_KEY_ID":keys["ACCESS_KEY_ID"],
                   "SECRET_ACCESS_KEY":keys["SECRET_ACCESS_KEY"]}},sys.stdout)' \
  | kubectl apply -f - >/dev/null
log "✓ cnpg-backup-creds present in data (cnpg.io/reload on; values never printed)"

# Backup GENERATION — one per cluster incarnation. barman will not archive
# into a prefix written by a previous cluster, so serverName must change on
# every apply-from-scratch while staying STABLE across re-runs on the same
# cluster: the in-cluster ConfigMap is the source of truth (survives
# re-runs, dies with the cluster), and SSM under the persistent prefix
# records the latest generation so the restore drill can select its origin
# after a destroy.
GEN=$(kubectl -n data get configmap cnpg-backup-generation \
  -o jsonpath='{.data.generation}' 2>/dev/null || true)
if [ -z "${GEN}" ]; then
  GEN="$(date -u +%Y%m%dt%H%M%Sz)"
  kubectl -n data create configmap cnpg-backup-generation \
    --from-literal=generation="${GEN}"
  log "✓ New backup generation minted: logistics-pg-${GEN}"
else
  log "✓ Existing backup generation reused: logistics-pg-${GEN}"
fi
CNPG_SERVER_NAME="logistics-pg-${GEN}"
# The SSM record runs on EVERY pass (idempotent --overwrite), outside the
# mint block: if the put failed on the first run, the next re-run repairs
# it instead of leaving the drill without its origin pointer forever.
aws ssm put-parameter \
  --name "/k8s/persistent/${CLUSTER_NAME}/cnpg-server-name" \
  --type String --overwrite \
  --value "${CNPG_SERVER_NAME}" \
  --region "${AWS_REGION}" >/dev/null
log "✓ SSM cnpg-server-name = ${CNPG_SERVER_NAME}"

log "Step 10/12: Data layer — PostgreSQL (CNPG x3) + Kafka (Strimzi KRaft x3)"
DATA="$(cd "$(dirname "${BASH_SOURCE[0]}")/data" && pwd)"
# Whole directory EXCEPT cnpg-cluster.yaml, which carries __BACKUP_BUCKET__
# and is templated — never applied raw (a literal placeholder would poison
# the barman destinationPath).
for f in "${DATA}"/*.yaml; do
  case "$(basename "${f}")" in
    cnpg-cluster.yaml)
      sed -e "s|__BACKUP_BUCKET__|${BACKUP_BUCKET}|g" \
          -e "s|__SERVER_NAME__|${CNPG_SERVER_NAME}|g" "${f}" | kubectl apply -f -
      ;;
    *)
      kubectl apply -f "${f}"
      ;;
  esac
done
# CNPG's enablePodMonitor is deprecated and no longer set: remove any
# operator-generated PodMonitor left behind so it never coexists (and
# double-scrapes) with the explicit one (cnpg-logistics-pg).
kubectl -n data delete podmonitor logistics-pg --ignore-not-found >/dev/null 2>&1 || true
# Wait for BOTH clusters to be healthy BEFORE their network policies land
# (phase-2 brief: never debug bootstrap and policy at the same time).
kubectl -n data wait cluster/logistics-pg \
  --for=jsonpath='{.status.phase}'='Cluster in healthy state' --timeout=600s
# auto.create.topics.enable=false rolls the brokers — wait Ready, then verify
# the cluster still serves (the smoke's produce/consume is the deeper check).
kubectl -n data wait kafka/logistics-kafka --for=condition=Ready --timeout=600s
log "✓ Data layer healthy (PG primary+2 sync replicas; Kafka 3 KRaft nodes)"

log "Step 10b/12: KafkaTopics (platform owns the resource; Repo 2 the contract)"
# apply -f DATA/ is NON-recursive, so topics/ is applied explicitly here.
kubectl apply -f "${DATA}/topics/"
kubectl -n data wait --for=condition=Ready kafkatopic \
  -l app.kubernetes.io/part-of=k8s-vanilla-lab-data --timeout=180s
log "✓ KafkaTopics Ready (shipment.created, route.calculated — RF3, minISR2)"

log "Step 10c/12: Projecting data credentials into logistics (reentrant)"
# The app (developer RBAC) cannot read Secrets in data. Project the minimum
# it needs into logistics, stripping all source-object metadata. Rotation
# until External Secrets (S3) = re-run this. Values never printed / no temp
# files (apply by pipe).
wait_secret() {  # ns name — poll up to 300s, clear error on timeout
  local ns="$1" name="$2" elapsed=0
  until kubectl -n "${ns}" get secret "${name}" >/dev/null 2>&1; do
    if [ "${elapsed}" -ge 300 ]; then
      echo "✗ source secret ${ns}/${name} not present after 300s" >&2
      exit 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
}
wait_secret data logistics-pg-app
# PG: type + full data, no source-object metadata.
kubectl -n data get secret logistics-pg-app -o json \
  | python3 -c '
import json,sys
s=json.load(sys.stdin)
json.dump({"apiVersion":"v1","kind":"Secret",
     "metadata":{"name":"logistics-pg-app","namespace":"logistics"},
     "type":s["type"],"data":s["data"]},sys.stdout)' \
  | kubectl apply -f - >/dev/null
wait_secret data logistics-kafka-cluster-ca-cert
# Kafka: ONLY the CA cert — never ca.key, PKCS12 or passwords.
kubectl -n data get secret logistics-kafka-cluster-ca-cert -o json \
  | python3 -c '
import json,sys
s=json.load(sys.stdin)
json.dump({"apiVersion":"v1","kind":"Secret",
     "metadata":{"name":"logistics-kafka-cluster-ca-cert","namespace":"logistics"},
     "type":"Opaque","data":{"ca.crt":s["data"]["ca.crt"]}},sys.stdout)' \
  | kubectl apply -f - >/dev/null
log "✓ Projected logistics/logistics-pg-app and logistics/logistics-kafka-cluster-ca-cert (ca.crt only)"

log "Step 11/12: Network policies — data operands + logistics app contract"
# By operand labels, not the whole namespace: the operators stay free.
kubectl apply -f "${POLICIES}/cnp-data-postgres.yaml"
kubectl apply -f "${POLICIES}/cnp-data-kafka.yaml"
# App contract (Repo 2): Prometheus scrape of app pods. No egress-to-Gateway
# policy: traffic to the Cilium Gateway VIP is to-proxy redirected before
# egress policy is evaluated, so a client-side CNP neither gates nor is
# needed for it (INCIDENTS #10). allowedRoutes already scopes routes to
# logistics.
kubectl apply -f "${POLICIES}/cnp-logistics-metrics.yaml"
log "✓ Network policies applied (data operands + logistics metrics contract)"

log "Step 12/12: Backups — etcd CronJob (6h) + CNPG ScheduledBackup (daily, immediate)"
sed -e "s|__BACKUP_BUCKET__|${BACKUP_BUCKET}|g" \
    -e "s|__AWS_REGION__|${AWS_REGION}|g" \
    "${BACKUP_DIR}/etcd-backup-cronjob.yaml" | kubectl apply -f -
kubectl apply -f "${BACKUP_DIR}/cnpg-scheduled-backup.yaml"
log "✓ Backups configured → s3://${BACKUP_BUCKET} (etcd/ every 6h · cnpg/ base+WAL continuous)"

log "=== Platform layer installed successfully ==="
log "Grafana NodePort: kubectl -n infra get svc kube-prometheus-stack-grafana"
