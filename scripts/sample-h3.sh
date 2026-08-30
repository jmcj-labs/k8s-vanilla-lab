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
# FAIL-CLOSED: every field is either a measured value or ERROR:<reason>. There
# is no default, no empty string standing in for a reading, and no branch that
# turns "could not measure" into a number. A gap is data; an invented zero is a
# lie, and this whole exercise exists because a health check answered without
# looking.
#
# READ-ONLY. It changes nothing: no health check, no security group, no Tofu.
set -euxo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
GATEWAY_NODEPORT="${GATEWAY_NODEPORT:-30443}"
INTERVAL="${INTERVAL:-5}"
OUT_DIR="${OUT_DIR:-/tmp/h3-$(date -u +%Y%m%dT%H%M%SZ)}"

mkdir -p "${OUT_DIR}"
SERIES="${OUT_DIR}/series"
TRACE="${OUT_DIR}/trace"
exec 2>>"${TRACE}"

note() { printf '%s\n' "$*" >>"${OUT_DIR}/meta"; }

# ── Resolution, once. A failure here is fatal: sampling against an unknown
# target group or an unknown set of workers would produce a series that looks
# like data and is not.
TG_ARN=$(aws elbv2 describe-target-groups --region "${AWS_REGION}" \
  --names "${CLUSTER_NAME}-gw-tg" --query 'TargetGroups[0].TargetGroupArn' --output text)
[ -n "${TG_ARN}" ] && [ "${TG_ARN}" != "None" ] || { echo "cannot resolve gateway target group" >&2; exit 1; }

NLB_DNS=$(aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
  --names "${CLUSTER_NAME}-gw-nlb" --query 'LoadBalancers[0].DNSName' --output text)
[ -n "${NLB_DNS}" ] && [ "${NLB_DNS}" != "None" ] || { echo "cannot resolve NLB DNS" >&2; exit 1; }

WORKER_IPS=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:Role,Values=worker" \
            "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PrivateIpAddress' --output text | tr '\t' ' ')
[ -n "${WORKER_IPS}" ] || { echo "no running workers found" >&2; exit 1; }

# The TCP probes need a vantage point INSIDE the VPC. Any control plane will do:
# the worker SG admits all traffic from the control-plane SG.
PROBE_HOST=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}-cp-0" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ -n "${PROBE_HOST}" ] && [ "${PROBE_HOST}" != "None" ] || { echo "cannot resolve cp-0 as probe host" >&2; exit 1; }

note "cluster=${CLUSTER_NAME} region=${AWS_REGION} nodeport=${GATEWAY_NODEPORT}"
note "tg=${TG_ARN}"
note "nlb=${NLB_DNS}"
note "workers=${WORKER_IPS}"
note "probe_host=${PROBE_HOST}"
note "interval_target=${INTERVAL}s"
note "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── One SSM round trip per iteration probes every worker, so the cadence pays
# for one latency and not three.
probe_workers() {
  local cid st out
  local cmd="for ip in ${WORKER_IPS}; do if timeout 2 bash -c \"exec 3<>/dev/tcp/\$ip/${GATEWAY_NODEPORT}\" 2>/dev/null; then echo \"\$ip=open\"; else echo \"\$ip=closed\"; fi; done"
  set +e
  cid=$(aws ssm send-command --region "${AWS_REGION}" --instance-ids "${PROBE_HOST}" \
    --document-name AWS-RunShellScript --parameters "commands=[\"${cmd}\"]" \
    --timeout-seconds 30 --query 'Command.CommandId' --output text 2>&1)
  local rc=$?
  set -e
  if [ ${rc} -ne 0 ] || [ -z "${cid}" ]; then
    printf 'ERROR:send-command-rc%s' "${rc}"
    return 0
  fi
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    set +e
    st=$(aws ssm get-command-invocation --region "${AWS_REGION}" --command-id "${cid}" \
      --instance-id "${PROBE_HOST}" --query 'Status' --output text 2>/dev/null)
    set -e
    case "${st}" in Success|Failed|TimedOut|Cancelled) break ;; esac
    sleep 1
  done
  if [ "${st}" != "Success" ]; then
    printf 'ERROR:ssm-status-%s' "${st:-unknown}"
    return 0
  fi
  set +e
  out=$(aws ssm get-command-invocation --region "${AWS_REGION}" --command-id "${cid}" \
    --instance-id "${PROBE_HOST}" --query 'StandardOutputContent' --output text 2>/dev/null)
  rc=$?
  set -e
  if [ ${rc} -ne 0 ] || [ -z "${out}" ]; then
    printf 'ERROR:no-output'
    return 0
  fi
  printf '%s' "$(printf '%s' "${out}" | tr '\n' ',' | sed 's/,$//')"
}

trap 'note "stopped=$(date -u +%Y-%m-%dT%H:%M:%SZ)"' EXIT

while true; do
  ITER_START=$(date +%s)
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # (a) What the load balancer believes.
  set +e
  TGT=$(aws elbv2 describe-target-health --region "${AWS_REGION}" --target-group-arn "${TG_ARN}" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text 2>&1)
  TGT_RC=$?
  set -e
  if [ ${TGT_RC} -ne 0 ]; then
    TGT_F="ERROR:describe-target-health-rc${TGT_RC}"
  else
    TGT_F=$(printf '%s' "${TGT}" | tr '\t' '=' | tr '\n' ',' | sed 's/,$//')
    [ -n "${TGT_F}" ] || TGT_F="ERROR:empty-target-list"
  fi

  # (b) What is actually true at each worker's NodePort. THE MISSING DATUM.
  TCP_F=$(probe_workers)

  # (c) What a client outside gets through the NLB, as in 4a.
  set +e
  HTTP_CODE=$(curl -sk --max-time 4 -o /dev/null -w '%{http_code}' \
    --connect-to "shipments.logistics.lab:443:${NLB_DNS}:443" \
    "https://shipments.logistics.lab/" 2>/dev/null)
  CURL_RC=$?
  set -e
  if [ ${CURL_RC} -ne 0 ]; then
    NLB_F="ERROR:curl-rc${CURL_RC}"
  else
    NLB_F="http${HTTP_CODE}"
  fi

  # (d) The DaemonSet counts the table in INCIDENTS #20 already carried.
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
  [ ${DSA_RC} -eq 0 ] || DSA="ERROR:kubectl-rc${DSA_RC}"
  [ ${DSE_RC} -eq 0 ] || DSE="ERROR:kubectl-rc${DSE_RC}"
  if [ ${PODS_RC} -eq 0 ]; then
    PODS_F=$(printf '%s' "${PODS}" | tr -s ' ' '=' | tr '\n' ',' | sed 's/,$//')
    [ -n "${PODS_F}" ] || PODS_F="ERROR:no-envoy-pods"
  else
    PODS_F="ERROR:kubectl-rc${PODS_RC}"
  fi

  ITER_MS=$(( ($(date +%s) - ITER_START) ))
  printf '%s tg=[%s] tcp=[%s] nlb=%s ds_agent=%s ds_envoy=%s pods=[%s] iter=%ss\n' \
    "${TS}" "${TGT_F}" "${TCP_F}" "${NLB_F}" "${DSA}" "${DSE}" "${PODS_F}" "${ITER_MS}" \
    >>"${SERIES}"

  SLEEP=$(( INTERVAL - ITER_MS ))
  [ ${SLEEP} -gt 0 ] || SLEEP=0
  [ ${SLEEP} -eq 0 ] || sleep "${SLEEP}"
done
