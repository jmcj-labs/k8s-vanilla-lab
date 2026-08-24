#!/usr/bin/env bash
# Server-side diff for one CRD manifest, with an HONEST conflict detector.
#
# WHY THIS EXISTS: at the v1.4.1 rung an ad-hoc `grep -c conflict` over the
# diff reported FOUR conflicts that did not exist. All four were prose inside
# the OpenAPI schema — the listener condition `Reason: Conflicted` and a note
# about "conflict resolution". Counting occurrences of a word is not detecting
# a state, and on a ladder where a real conflict means STOP, a detector that
# cries wolf is as harmful as one that stays quiet.
#
# The authority here is kubectl's own exit code plus the server's exact error
# line, never a substring of the payload:
#   rc=0  no differences
#   rc=1  differences, no error        → the normal case for a rung
#   rc>1  the command itself failed    → conflict or anything else: STOP
set -euo pipefail

MANIFEST="${1:-}"
LABEL="${2:-$(basename "${MANIFEST}")}"
FM="${CRD_FIELD_MANAGER:-gateway-api-crd-upgrade}"
OUT="${CRD_DIFF_OUT:-$(mktemp)}"

[ -n "${MANIFEST}" ] || { echo "usage: $0 <manifest-url-or-file> [label]" >&2; exit 2; }

set +e
kubectl diff --server-side --field-manager="${FM}" -f "${MANIFEST}" > "${OUT}" 2>&1
RC=$?
set -e

# The server names a real conflict on its own line. Anchored, exact, and
# immune to the word appearing in a description a thousand lines down.
CONFLICT=$(grep -cE '^Error from server \(Conflict\)' "${OUT}" || true)
OTHERERR=$(grep -cE '^Error from server' "${OUT}" || true)

echo "=== diff: ${LABEL} ==="
echo "  rc=${RC}  lines=$(wc -l < "${OUT}" | tr -d ' ')  diff saved: ${OUT}"

if [ "${CONFLICT}" -gt 0 ]; then
  echo "  ✗ REAL CONFLICT — stop and inspect managedFields before applying:" >&2
  grep -E '^Error from server \(Conflict\)' "${OUT}" | sed 's/^/    /' >&2
  exit 3
fi
if [ "${OTHERERR}" -gt 0 ]; then
  echo "  ✗ server error that is NOT a conflict — stop:" >&2
  grep -E '^Error from server' "${OUT}" | sed 's/^/    /' >&2
  exit 4
fi
case "${RC}" in
  0) echo "  ✓ no differences (already at this version)" ;;
  1) echo "  ✓ differences, NO conflict — safe to apply without --force-conflicts" ;;
  *) echo "  ✗ kubectl diff failed with rc=${RC} and no recognisable server error." >&2
     tail -5 "${OUT}" | sed 's/^/    /' >&2
     echo "  A diff we cannot interpret is not a clean diff." >&2
     exit 5 ;;
esac
