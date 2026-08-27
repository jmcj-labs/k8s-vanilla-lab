#!/usr/bin/env bash
# Stub payload library. Unlike joined-count.sh or kpr-gate.sh this one rides
# INLINE in user_data, because it is what fetches everything else.
# Keep this file ASCII-only: it becomes part of the cloud-init payload.
#
# Requires log() from the caller.
#
# INCIDENTS #25: the founder render travelled inline and had reached 16289 of
# the 16384 bytes EC2 allows. Sixty added lines broke RunInstances on index 0.
# The renders now travel through S3; only this stub rides in user_data, so the
# transport budget stops competing with the comments that document #22-#24.

# fetch_and_exec <s3_uri> <sha256> <dest> <deadline_seconds> <interval_seconds>
#
# Every attempt runs under `timeout` bounded by the remaining budget (capped at
# 60s) with the AWS CLI's own connect/read timeouts, so a hung call cannot
# outlive the deadline -- the house shape for reads that must not hang.
#
# NEVER executes what it has not verified. A download can be retried; a hash
# mismatch cannot -- it means the bytes are not the ones tofu rendered, and
# running them anyway is the one outcome this stub exists to prevent.
fetch_and_exec() {
  local uri="$1" want="$2" dest="$3" deadline="$4" interval="$5"
  local start now remaining attempt nap out rc got
  start=$(date +%s)
  out="(no attempt completed)"
  rc=0
  mkdir -p "$(dirname "${dest}")"

  while true; do
    # Budget FIRST: a hung CLI must not be able to outlive the deadline just
    # because the loop only checks the clock after the call returns. Each
    # attempt is bounded by whatever is left, capped at 60s.
    remaining=$(( deadline - ( $(date +%s) - start ) ))
    if [ "${remaining}" -le 0 ]; then
      log "ERROR: could not fetch ${uri} within ${deadline}s (last rc=${rc})"
      printf '%s\n' "${out}" | sed 's/^/  /'
      return 1
    fi
    attempt=$(( remaining < 60 ? remaining : 60 ))

    set +e
    out=$(timeout "${attempt}" aws s3 cp "${uri}" "${dest}" \
      --only-show-errors --cli-connect-timeout 5 --cli-read-timeout 30 2>&1)
    rc=$?
    set -e
    if [ "${rc}" -eq 0 ]; then
      break
    fi

    now=$(( $(date +%s) - start ))
    if [ "${now}" -ge "${deadline}" ]; then
      log "ERROR: could not fetch ${uri} within ${now}s (last rc=${rc})"
      printf '%s\n' "${out}" | sed 's/^/  /'
      return 1
    fi
    # Never sleep past the deadline either.
    remaining=$(( deadline - now ))
    nap=$(( remaining < interval ? remaining : interval ))
    if [ "${nap}" -gt 0 ]; then
      sleep "${nap}"
    fi
  done

  got=$(sha256sum "${dest}" | awk '{print $1}')
  if [ "${got}" != "${want}" ]; then
    log "ERROR: ${uri} failed SHA-256 verification -- refusing to execute it"
    log "  expected ${want}"
    log "  got      ${got}"
    rm -f "${dest}"
    return 1
  fi
  log "OK fetched and verified ${uri} after $(( $(date +%s) - start ))s"

  chmod 0700 "${dest}"
  set +e
  "${dest}"
  rc=$?
  set -e
  if [ "${rc}" -ne 0 ]; then
    log "ERROR: ${dest} exited ${rc}"
    return "${rc}"
  fi
  return 0
}
