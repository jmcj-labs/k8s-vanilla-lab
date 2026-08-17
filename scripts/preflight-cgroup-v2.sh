#!/usr/bin/env bash
# PRE-FLIGHT — cgroup v2 on every node, before touching Kubernetes 1.36.
#
# 1.36 rejects cgroup v1 by default. Discovering that DURING a rolling
# kubelet upgrade means finding out when a node is already drained and its
# kubelet will not come back — so this runs BEFORE anything, and it is a
# gate, not a report: any node that cannot be PROVEN to be on v2 fails the
# whole check (INCIDENTS #17 — "I could not tell" is a failure).
#
# Uses the out-of-band channel (SSM Run Command, INCIDENTS #16) so it works
# whether or not the API is healthy.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
log()  { echo "[$(date -u +'%H:%M:%SZ')] $*"; }
FAIL() { echo "✗ $*" >&2; exit 1; }
OK()   { echo "  ✓ $*"; }

# shellcheck source=scripts/lib/ssm-exec.sh
. "$(dirname "$0")/lib/ssm-exec.sh"

IDS=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n' | sort)
COUNT=$(echo "${IDS}" | grep -c . || true)
[ "${COUNT}" -gt 0 ] || FAIL "no running cluster nodes found"
log "checking cgroup v2 on ${COUNT} nodes"

BAD=0
for IID in ${IDS}; do
  # The unified hierarchy mounts cgroup2fs at /sys/fs/cgroup. `stat -fc %T`
  # answers the question directly: cgroup2fs (v2) vs tmpfs (v1 hybrid).
  set +e
  OUT=$(SSM_EXEC_TIMEOUT=60 ssm_run "${IID}" \
    'stat -fc %T /sys/fs/cgroup; hostname' 2>/dev/null)
  RC=$?
  set -e
  FS=$(printf '%s' "${OUT}" | head -1 | tr -d '[:space:]')
  HOST=$(printf '%s' "${OUT}" | tail -1 | tr -d '[:space:]')
  if [ ${RC} -ne 0 ]; then
    echo "  ✗ ${IID}: could not determine the cgroup version (channel error)" >&2
    BAD=$((BAD + 1)); continue
  fi
  case "${FS}" in
    cgroup2fs) OK "${HOST:-${IID}}: cgroup v2 (cgroup2fs)" ;;
    "")        echo "  ✗ ${IID}: empty answer — cannot prove v2" >&2; BAD=$((BAD + 1)) ;;
    *)         echo "  ✗ ${HOST:-${IID}}: NOT cgroup v2 (found '${FS}') — 1.36 would refuse to start the kubelet" >&2
               BAD=$((BAD + 1)) ;;
  esac
done

[ "${BAD}" -eq 0 ] || FAIL "${BAD} of ${COUNT} nodes are not proven to be on cgroup v2 — do NOT start the Kubernetes upgrade"
log "✓ all ${COUNT} nodes on cgroup v2 — this pre-flight does not block the 1.36 upgrade"
