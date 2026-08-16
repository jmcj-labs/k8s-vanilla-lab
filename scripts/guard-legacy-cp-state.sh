#!/usr/bin/env bash
# Refuse to apply the HA control plane (S2 piece 3) on top of a state that
# still holds the PRE-HA singleton control plane.
#
# WHY THIS IS A HARD STOP, not a warning: cloud-init is FIRST-BOOT ONLY and
# the CP instance ignores user_data changes by lifecycle. A singleton CP
# already in state would survive the apply carrying the OLD endpoint
# (`controlPlaneEndpoint` = its own private IP) while the new CPs boot
# anchored to the NLB — two irreconcilable clusters, silently. The only
# valid operation is: DESTROY the old cluster completely, then apply from
# an empty state (brief #S2-3: "recreate completo, NO migración in-place").
#
# FAIL CLOSED. A security guard that cannot read the state must ABORT, never
# assume "no state, must be fresh": credentials, backend, lock or
# serialization failures are UNKNOWN, and unknown is not safe. Only two
# outcomes let the apply through — a state that reads clean, and a state
# that provably does not exist yet.
#
# Invoked by `make apply` and by the CI apply workflow, before tofu apply.
# Requires an initialized working dir (tofu init already run).
set -euo pipefail

TOFU_DIR="${TOFU_DIR:-tofu/envs/lab}"

STDERR_FILE=$(mktemp)
trap 'rm -f "${STDERR_FILE}"' EXIT

set +e
STATE=$(cd "${TOFU_DIR}" && tofu state list 2>"${STDERR_FILE}")
RC=$?
set -e
STDERR=$(cat "${STDERR_FILE}")

if [ "${RC}" -ne 0 ]; then
  # The ONE non-zero exit that is not a failure: no state object exists yet
  # (a brand-new backend key). Everything else — expired credentials, a
  # denied or unreachable backend, a held lock, an unreadable or
  # future-versioned snapshot — is an UNKNOWN state, and the guard must not
  # let an apply run against an unknown state.
  if echo "${STDERR}" | grep -qiE 'no state file was found|state file (does not exist|not found)'; then
    echo "✓ recreate guard: no state object yet — fresh apply"
    exit 0
  fi
  cat >&2 <<EOF
✗ recreate guard: COULD NOT READ THE STATE — refusing to apply.

  tofu state list exited ${RC} in ${TOFU_DIR}:
$(echo "${STDERR}" | sed 's/^/    /')

This guard fails CLOSED: an unreadable state cannot be proven free of the
pre-HA singleton control plane, and applying blindly could produce two
irreconcilable clusters (ADR-007).

Usual causes: expired AWS credentials (aws sso login --profile ...), the
working directory not initialised (make init), or a locked/unreachable S3
backend. Fix the cause and re-run — do NOT bypass this script.
EOF
  exit 1
fi

if [ -z "${STATE}" ]; then
  echo "✓ recreate guard: empty state — fresh apply"
  exit 0
fi

# Legacy markers, all impossible in the HA layout:
#   - the un-indexed singleton instance (HA is control_plane[0..N])
#   - the control plane EIP and its association (deleted in piece 3)
#   - the world-facing API ingress rule (replaced by the NLB SG reference)
LEGACY=$(echo "${STATE}" | grep -E \
  '^module\.control_plane\.aws_instance\.control_plane$|^module\.control_plane\.aws_eip(_association)?\.control_plane$|^module\.control_plane\.aws_vpc_security_group_ingress_rule\.api_server' \
  || true)

if [ -n "${LEGACY}" ]; then
  cat >&2 <<EOF
✗ recreate guard: this state still holds the PRE-HA control plane.

Legacy resources found in state:
$(echo "${LEGACY}" | sed 's/^/    /')

The HA control plane (S2 piece 3, ADR-007) CANNOT be migrated in place:
cloud-init runs only on first boot and the existing node would keep the old
API endpoint while the new ones anchor to the NLB.

DESTROY FIRST, then apply from an empty state:

    make destroy          # or the "OpenTofu Destroy" workflow
    make apply            # rebuilds the 3 HA control planes from scratch

Backups survive the destroy (persistent bucket, S2 piece 1): see
docs/RUNBOOK-post-apply.md for the post-recreate handoff (K8S_SERVER and
K8S_CA_DATA rotate with every incarnation).
EOF
  exit 1
fi

echo "✓ recreate guard: state readable, no legacy singleton control plane"
