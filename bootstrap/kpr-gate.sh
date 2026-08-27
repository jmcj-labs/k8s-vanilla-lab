#!/usr/bin/env bash
# Live-datapath gate injected into control-plane.yaml by templatefile.
# Keep this file ASCII-only: it becomes part of the cloud-init payload.
#
# Requires log() from the caller (the founder defines it).
#
# THE GATE IS "cilium-dbg ANSWERS", NOT "THE POD IS Ready". Ready was the
# adjacent signal of INCIDENTS #24: the agent passed its readiness probe at
# 09:51:19 and was still logging "Initializing daemon" when this exec ran one
# second later. The founder died mute, because the exec's stderr had been
# discarded with 2>/dev/null and pipefail turned the swallowed failure into a
# bare `set -e` abort before the guard could report anything.
#
# So: never 2>/dev/null here. The captured stderr IS the diagnosis -- #24
# could not settle which end of the pipeline failed precisely because it was
# thrown away.

# Field 2 of the whitespace-split line. Splitting on ':' truncated the value
# at the first colon inside the device list's IPv6 address (INCIDENTS #23):
#   KubeProxyReplacement:    True   [ens5   10.0.1.37 fe80::... (Direct Routing)]
kpr_token() {
  awk '$1 == "KubeProxyReplacement:" {print $2; exit}'
}

# kpr_gate <deadline_seconds> <interval_seconds>
#   0 = the live datapath answered exactly True.
#   1 = it answered something else, or never answered before the deadline.
#
# An agent that is still starting is a legitimate transient and is retried.
# A datapath that ANSWERS False is a verdict, not a transient: waiting cannot
# mend it, so that decision is taken at once and without another attempt.
kpr_gate() {
  local deadline="$1" interval="$2" start now out rc token
  start=$(date +%s)
  while true; do
    set +e
    out=$(kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>&1)
    rc=$?
    set -e

    if [ "${rc}" -eq 0 ]; then
      token=$(printf '%s\n' "${out}" | kpr_token)
      if [ "${token}" = "True" ]; then
        log "OK live datapath answered KubeProxyReplacement=True after $(( $(date +%s) - start ))s"
        return 0
      fi
      log "ERROR: live Cilium datapath reports KubeProxyReplacement='${token}' (expected exactly True)"
      printf '%s\n' "${out}" | grep -i kubeproxyreplacement | sed 's/^/  /' || true
      return 1
    fi

    now=$(( $(date +%s) - start ))
    if [ "${now}" -ge "${deadline}" ]; then
      log "ERROR: cilium-dbg did not answer within ${now}s (last rc=${rc})"
      printf '%s\n' "${out}" | sed 's/^/  /'
      return 1
    fi
    sleep "${interval}"
  done
}
