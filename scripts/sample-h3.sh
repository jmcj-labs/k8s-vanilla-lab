#!/usr/bin/env bash
# H3 SAMPLER — does the NLB's TCP health check notice a node whose Envoy is dead?
#
# INCIDENTS #20 states H3 as VERIFIED FROM THE TARGET GROUP'S CONFIGURATION and
# never observed live. The v2 runbook (origin/docs/4a-v2-live-capture, 03235e6)
# designed a sampler for it and 4a-v2 was never executed, so the series it would
# have produced does not exist. This is that sampler, with the one stream it was
# missing: a TCP attempt against each worker's NodePort, taken directly and NOT
# inferred from what the target group reports.
#
# WHERE EACH PROBE RUNS, and why it is not all in one place:
#   - target health, DaemonSet counts, NLB entry  -> from here (operator host)
#   - per-worker TCP to :30443                    -> from a control plane, via
#     SSM Run Command, because the worker SG admits 30443 ONLY from the NLB's
#     security group. From this host it is closed BY DESIGN, and the smoke test
#     asserts exactly that ("NodePort closed on EVERY worker public IP"). A
#     probe from here would measure the firewall, not the datapath.
#
# ONE TIMESTAMP PER FIELD, not per row. A round trip through SSM can take
# several seconds, so a row stamped once at its start would present readings
# taken up to ~12s apart as if they were simultaneous — states that never
# coexisted. Every field carries the instant it was actually read.
#
# FAIL-CLOSED: every field is either a measured value or ERROR:<reason>. There
# is no default, no empty string standing in for a reading, and no branch that
# turns "could not measure" into a plausible value. In particular a tool failure
# on the probe host is ERROR and never "closed" — "closed" is a finding about
# the datapath and must never be manufactured by a missing binary.
#
# READ-ONLY. It changes nothing: no health check, no security group, no Tofu.
set -euxo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
GATEWAY_NODEPORT="${GATEWAY_NODEPORT:-30443}"
INTERVAL="${INTERVAL:-5}"
POINTER="${POINTER:-/tmp/h3-current}"

# ── mark: stamps an operator action into the series of the running sampler.
# The instant of the kill -STOP and of the kill -CONT are the origin of the
# whole timeline; without them in the same file the series cannot be read.
if [ "${1:-}" = "mark" ]; then
  shift
  [ -f "${POINTER}" ] || { echo "no running sampler: ${POINTER} not found" >&2; exit 1; }
  MARK_DIR=$(cat "${POINTER}")
  [ -d "${MARK_DIR}" ] || { echo "sampler dir ${MARK_DIR} does not exist" >&2; exit 1; }
  printf '%s event=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"${MARK_DIR}/series"
  exit 0
fi

OUT_DIR="${OUT_DIR:-/tmp/h3-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "${OUT_DIR}"
SERIES="${OUT_DIR}/series"
TRACE="${OUT_DIR}/trace"
META="${OUT_DIR}/meta"
exec 2>>"${TRACE}"
printf '%s' "${OUT_DIR}" >"${POINTER}"

note() { printf '%s\n' "$*" >>"${META}"; }
now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Resolution, once. A failure here is fatal: sampling against an unknown
# target group or an unknown set of workers would produce a series that looks
# like data and is not.
TG_ARN=$(aws elbv2 describe-target-groups --region "${AWS_REGION}" \
  --names "${CLUSTER_NAME}-gw-tg" --query 'TargetGroups[0].TargetGroupArn' --output text)
[ -n "${TG_ARN}" ] && [ "${TG_ARN}" != "None" ] || { echo "cannot resolve gateway target group" >&2; exit 1; }

NLB_DNS=$(aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
  --names "${CLUSTER_NAME}-gw-nlb" --query 'LoadBalancers[0].DNSName' --output text)
[ -n "${NLB_DNS}" ] && [ "${NLB_DNS}" != "None" ] || { echo "cannot resolve NLB DNS" >&2; exit 1; }

# ── IDENTITY MAP. The three streams speak three different names for the same
# machine: the target group reports instance-ids, the TCP probe uses private
# IPs, and the DaemonSet reports nodeNames. Without this table in meta the
# fields cannot be cross-read, and "which worker is the intervened one" cannot
# be answered from the series.
WORKERS=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:Role,Values=worker" \
            "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress]' --output text)
[ -n "${WORKERS}" ] || { echo "no running workers found" >&2; exit 1; }

WORKER_IPS=$(printf '%s\n' "${WORKERS}" | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')
WORKER_COUNT=$(printf '%s\n' "${WORKERS}" | grep -c .)

NODE_MAP=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{.metadata.name}{"\n"}{end}')
[ -n "${NODE_MAP}" ] || { echo "cannot read node InternalIP -> nodeName map" >&2; exit 1; }

PROBE_HOST=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}-cp-0" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ -n "${PROBE_HOST}" ] && [ "${PROBE_HOST}" != "None" ] || { echo "cannot resolve cp-0 as probe host" >&2; exit 1; }

note "cluster=${CLUSTER_NAME} region=${AWS_REGION} nodeport=${GATEWAY_NODEPORT}"
note "tg=${TG_ARN}"
note "nlb=${NLB_DNS}"
note "probe_host=${PROBE_HOST}"
note "interval_target=${INTERVAL}s"
note "worker_count=${WORKER_COUNT}"
note "--- identity map: instance-id  private-ip  nodeName ---"
while read -r WID WIP; do
  [ -n "${WID}" ] || continue
  WNODE=$(printf '%s\n' "${NODE_MAP}" | awk -v ip="${WIP}" '$1 == ip {print $2}')
  [ -n "${WNODE}" ] || WNODE="ERROR:no-node-for-ip"
  note "${WID}  ${WIP}  ${WNODE}"
done <<<"${WORKERS}"
note "started=$(now)"

# ── One SSM round trip per iteration probes every worker, so the cadence pays
# for one latency and not three.
#
# The remote loop distinguishes three outcomes and NEVER collapses a tool
# failure into "closed": bash's /dev/tcp returns 1 when the connection is
# refused, `timeout` returns 124 when it expires (filtered, or no route), and
# anything else is the probe itself failing. The earlier version reported
# "closed" for all of them, which is the reading that would have been taken as
# "the experiment did not isolate Envoy".
read -r -d '' REMOTE_CMD <<'REMOTE' || true
for ip in __IPS__; do
  err=$( { timeout 2 bash -c "exec 3<>/dev/tcp/${ip}/__PORT__"; } 2>&1 )
  rc=$?
  if [ ${rc} -eq 0 ]; then
    echo "${ip}=open"
  elif [ ${rc} -eq 1 ]; then
    echo "${ip}=closed"
  elif [ ${rc} -eq 124 ]; then
    echo "${ip}=timeout"
  else
    echo "${ip}=ERROR:rc${rc}:$(echo "${err}" | tr -d '\n' | cut -c1-60)"
  fi
done
REMOTE
REMOTE_CMD=${REMOTE_CMD//__IPS__/${WORKER_IPS}}
REMOTE_CMD=${REMOTE_CMD//__PORT__/${GATEWAY_NODEPORT}}

probe_workers() {
  local cid st out rc i payload
  # --cli-input-json takes the API shape, not just the parameter map: the
  # commands list lives under Parameters. Getting this wrong is rc 252 and the
  # series showed ERROR:send-command-rc252 rather than a plausible value, which
  # is the fail-closed behaviour doing its job.
  payload=$(printf '%s' "${REMOTE_CMD}" | python3 -c 'import json,sys; print(json.dumps({"Parameters":{"commands":[sys.stdin.read()]}}))')
  set +e
  cid=$(aws ssm send-command --region "${AWS_REGION}" --instance-ids "${PROBE_HOST}" \
    --document-name AWS-RunShellScript --cli-input-json "${payload}" \
    --timeout-seconds 30 --query 'Command.CommandId' --output text 2>&1)
  rc=$?
  set -e
  if [ ${rc} -ne 0 ] || [ -z "${cid}" ]; then printf 'ERROR:send-command-rc%s' "${rc}"; return 0; fi

  st=""
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    set +e
    st=$(aws ssm get-command-invocation --region "${AWS_REGION}" --command-id "${cid}" \
      --instance-id "${PROBE_HOST}" --query 'Status' --output text 2>/dev/null)
    set -e
    case "${st}" in Success|Failed|TimedOut|Cancelled) break ;; esac
    sleep 1
  done
  if [ "${st}" != "Success" ]; then printf 'ERROR:ssm-status-%s' "${st:-unknown}"; return 0; fi

  set +e
  out=$(aws ssm get-command-invocation --region "${AWS_REGION}" --command-id "${cid}" \
    --instance-id "${PROBE_HOST}" --query 'StandardOutputContent' --output text 2>/dev/null)
  rc=$?
  set -e
  if [ ${rc} -ne 0 ] || [ -z "${out}" ]; then printf 'ERROR:no-output'; return 0; fi

  # EXACTLY one entry per worker. A partial answer is not a partial reading of
  # the cluster, it is a broken reading of the probe.
  local got
  got=$(printf '%s\n' "${out}" | grep -c '=')
  if [ "${got}" -ne "${WORKER_COUNT}" ]; then
    printf 'ERROR:partial-%s-of-%s' "${got}" "${WORKER_COUNT}"
    return 0
  fi
  printf '%s' "$(printf '%s' "${out}" | tr '\n' ',' | sed 's/,$//')"
}

trap 'note "stopped=$(now)"; rm -f "${POINTER}"' EXIT

while true; do
  ITER_START=$(date +%s)

  # (a) What the load balancer believes.
  TS_TG=$(now)
  set +e
  TGT=$(aws elbv2 describe-target-health --region "${AWS_REGION}" --target-group-arn "${TG_ARN}" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text 2>&1)
  TGT_RC=$?
  set -e
  if [ ${TGT_RC} -ne 0 ]; then
    TGT_F="ERROR:describe-target-health-rc${TGT_RC}"
  else
    TGT_N=$(printf '%s\n' "${TGT}" | grep -c .)
    if [ "${TGT_N}" -ne "${WORKER_COUNT}" ]; then
      TGT_F="ERROR:partial-${TGT_N}-of-${WORKER_COUNT}"
    else
      TGT_F=$(printf '%s' "${TGT}" | tr '\t' '=' | tr '\n' ',' | sed 's/,$//')
    fi
  fi

  # (b) What is actually true at each worker's NodePort. THE MISSING DATUM.
  TS_TCP=$(now)
  TCP_F=$(probe_workers)

  # (c) What a client outside gets through the NLB. A transport failure is
  # ERROR, not evidence: the demonstration needs a POSITIVE signal (an HTTP
  # status the NLB returned), never the absence of a reading.
  TS_NLB=$(now)
  set +e
  HTTP_CODE=$(curl -sk --max-time 4 -o /dev/null -w '%{http_code}' \
    --connect-to "shipments.logistics.lab:443:${NLB_DNS}:443" \
    "https://shipments.logistics.lab/" 2>/dev/null)
  CURL_RC=$?
  set -e
  if [ ${CURL_RC} -ne 0 ]; then
    NLB_F="ERROR:curl-rc${CURL_RC}"
  elif [ -z "${HTTP_CODE}" ] || [ "${HTTP_CODE}" = "000" ]; then
    NLB_F="ERROR:no-http-status"
  else
    NLB_F="http${HTTP_CODE}"
  fi

  # (d) The DaemonSet counts the table in INCIDENTS #20 already carried.
  TS_DS=$(now)
  set +e
  DSA=$(kubectl -n kube-system get ds cilium \
    -o jsonpath='{.status.updatedNumberScheduled}/{.status.numberReady}' 2>&1)
  DSA_RC=$?
  DSE=$(kubectl -n kube-system get ds cilium-envoy \
    -o jsonpath='{.status.updatedNumberScheduled}/{.status.numberReady}' 2>&1)
  DSE_RC=$?
  PODS=$(kubectl -n kube-system get pods -l k8s-app=cilium-envoy \
    -o custom-columns='N:.spec.nodeName,R:.status.containerStatuses[0].ready' --no-headers 2>&1)
  PODS_RC=$?
  set -e
  # A jsonpath that matched nothing yields "/" — shaped like a reading and not one.
  if [ ${DSA_RC} -ne 0 ] || [ "${DSA}" = "/" ]; then DSA="ERROR:agent-ds-unreadable"; fi
  if [ ${DSE_RC} -ne 0 ] || [ "${DSE}" = "/" ]; then DSE="ERROR:envoy-ds-unreadable"; fi
  if [ ${PODS_RC} -eq 0 ]; then
    PODS_N=$(printf '%s\n' "${PODS}" | grep -c .)
    if [ "${PODS_N}" -lt "${WORKER_COUNT}" ]; then
      PODS_F="ERROR:only-${PODS_N}-envoy-pods"
    else
      PODS_F=$(printf '%s' "${PODS}" | tr -s ' ' '=' | tr '\n' ',' | sed 's/,$//')
    fi
  else
    PODS_F="ERROR:kubectl-rc${PODS_RC}"
  fi

  ITER_S=$(( $(date +%s) - ITER_START ))
  printf 'tg@%s=[%s] tcp@%s=[%s] nlb@%s=%s ds@%s agent=%s envoy=%s pods=[%s] iter=%ss\n' \
    "${TS_TG}" "${TGT_F}" "${TS_TCP}" "${TCP_F}" "${TS_NLB}" "${NLB_F}" \
    "${TS_DS}" "${DSA}" "${DSE}" "${PODS_F}" "${ITER_S}" >>"${SERIES}"

  SLEEP=$(( INTERVAL - ITER_S ))
  [ ${SLEEP} -gt 0 ] || SLEEP=0
  [ ${SLEEP} -eq 0 ] || sleep "${SLEEP}"
done
