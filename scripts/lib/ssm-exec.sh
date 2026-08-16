#!/usr/bin/env bash
# Out-of-band command execution on cluster nodes via SSM Run Command.
# Sourced by ceremonies and by the smoke — the single place that knows how
# to talk to a node without Kubernetes and without SSH (INCIDENTS #16).
#
# WHY Run Command and not Session Manager: `start-session` is interactive
# (TTY, needs the local plugin) and is the right tool for a human at a
# keyboard — `make ssm-cp` uses it. A scripted ceremony needs the opposite:
# non-interactive, an exit code it can branch on, and output it can assert.
# That is `send-command` with AWS-RunShellScript, which runs AS ROOT (no
# sudo) and reports both Status and ResponseCode.
#
# Expects: AWS_REGION, and credentials able to SendCommand/GetCommandInvocation.

# Every command id we launch, so a Ctrl-C on the operator's laptop does not
# leave a root shell running unattended on a control plane: Run Command
# keeps executing on the node even if the local shell dies.
SSM_INFLIGHT=""
ssm_cancel_inflight() {
  local id iid
  for id in ${SSM_INFLIGHT}; do
    aws ssm cancel-command --command-id "${id}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
  done
  SSM_INFLIGHT=""
}

# ssm_run <instance-id> <script…>
#   Runs the script as root on the node. Prints its stdout. Returns the
#   script's own exit code (not the API's), so callers branch normally.
#   SSM_EXEC_TIMEOUT  — seconds we are willing to wait for completion (default 600)
#   SSM_DELIVERY_TIMEOUT — seconds SSM may take to DELIVER it (default 120)
ssm_run() {
  local iid="$1"; shift
  local script="$*"
  local exec_timeout="${SSM_EXEC_TIMEOUT:-600}"
  local delivery_timeout="${SSM_DELIVERY_TIMEOUT:-120}"

  # Build the request with a JSON encoder rather than string-quoting: the
  # scripts carry quotes, pipes and newlines, and a hand-built
  # `commands=[...]` mangles them silently.
  local req; req=$(mktemp)
  SSM_IID="${iid}" SSM_SCRIPT="${script}" SSM_ET="${exec_timeout}" SSM_DT="${delivery_timeout}" \
  python3 - > "${req}" <<'PY'
import json, os
print(json.dumps({
    "InstanceIds": [os.environ["SSM_IID"]],
    "DocumentName": "AWS-RunShellScript",
    "TimeoutSeconds": int(os.environ["SSM_DT"]),
    "Parameters": {
        # AWS-RunShellScript runs the commands with /bin/sh — dash on
        # Ubuntu — which rejects `set -o pipefail` outright ("Illegal
        # option"). A shebang as the FIRST command IS honoured (verified
        # live 2026-08-16: it reported bash 5.2.21), so this is what buys
        # back the same strictness the SSH helper had.
        "commands": ["#!/bin/bash", "set -euo pipefail", os.environ["SSM_SCRIPT"]],
        # Document-level: how long the script may RUN on the node. Distinct
        # from TimeoutSeconds, which only bounds DELIVERY.
        "executionTimeout": [str(max(int(os.environ["SSM_ET"]), 30))],
    },
}))
PY

  local cmd_id
  cmd_id=$(aws ssm send-command --cli-input-json "file://${req}" \
    --region "${AWS_REGION}" --query Command.CommandId --output text 2>/dev/null) || {
      rm -f "${req}"; echo "ssm_run: send-command failed for ${iid}" >&2; return 90; }
  rm -f "${req}"
  SSM_INFLIGHT="${SSM_INFLIGHT} ${cmd_id}"

  local deadline=$(( $(date -u +%s) + exec_timeout + 60 ))
  local status="" rc="" out="" err="" raw=""
  while true; do
    # The invocation is eventually consistent: for the first moments after
    # send-command it legitimately does not exist yet. That is not an error.
    if raw=$(aws ssm get-command-invocation --command-id "${cmd_id}" \
               --instance-id "${iid}" --region "${AWS_REGION}" 2>/dev/null); then
      status=$(printf '%s' "${raw}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Status"])')
      case "${status}" in
        Pending|InProgress|Delayed) : ;;   # not terminal — keep waiting
        *) break ;;
      esac
    fi
    if [ "$(date -u +%s)" -ge "${deadline}" ]; then
      echo "ssm_run: timed out after ${exec_timeout}s (last status: ${status:-unknown}, command ${cmd_id})" >&2
      aws ssm cancel-command --command-id "${cmd_id}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
      return 91
    fi
    sleep 3
  done

  out=$(printf '%s' "${raw}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("StandardOutputContent",""), end="")')
  err=$(printf '%s' "${raw}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("StandardErrorContent",""), end="")')
  rc=$(printf '%s' "${raw}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ResponseCode",-1))')
  SSM_INFLIGHT="${SSM_INFLIGHT// ${cmd_id}/}"

  printf '%s' "${out}"
  if [ "${status}" != "Success" ]; then
    {
      echo "ssm_run: ${status} on ${iid} (exit ${rc}, command ${cmd_id})"
      [ -n "${err}" ] && echo "--- stderr ---" && printf '%s\n' "${err}"
    } >&2
    # Surface the script's own code when it has one; otherwise a distinct
    # code so callers can tell "the script failed" from "SSM failed".
    [ "${rc}" != "-1" ] && [ -n "${rc}" ] && return "${rc}"
    return 92
  fi
  return 0
}

# ssm_online <instance-id> — true if SSM considers the node reachable NOW.
ssm_online() {
  local iid="$1"
  [ "$(aws ssm describe-instance-information --region "${AWS_REGION}" \
        --filters "Key=InstanceIds,Values=${iid}" \
        --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" = "Online" ]
}

# ssm_canary <instance-id> — proves the channel end to end, not just that
# the agent pings: a command is delivered, executed and its exact output
# returned. "Online" alone has never been enough evidence for this house.
ssm_canary() {
  local iid="$1"
  local expect="oob-canary-ok"
  local got
  got=$(SSM_EXEC_TIMEOUT=60 SSM_DELIVERY_TIMEOUT=60 ssm_run "${iid}" "echo ${expect}") || return 1
  [ "$(printf '%s' "${got}" | tr -d '[:space:]')" = "${expect}" ]
}
