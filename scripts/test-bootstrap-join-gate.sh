#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=bootstrap/joined-count.sh
. "$ROOT/bootstrap/joined-count.sh"

expect() {
  local expected="$1" value="$2" index="$3" got
  got=$(joined_count_decision "$value" "$index" 3)
  [ "$got" = "$expected" ] || { echo "ERROR value=$value index=$index: got $got, want $expected" >&2; exit 1; }
}
expect wait 0 0
expect proceed 1 0
expect wait 0 1
expect proceed 1 1
expect wait 1 2
expect proceed 2 2
! joined_count_decision '' 1 3 >/dev/null
! joined_count_decision garbage 1 3 >/dev/null
! joined_count_decision 1 garbage 3 >/dev/null
! joined_count_decision 4 1 3 >/dev/null
! joined_count_decision 1 3 3 >/dev/null
[ "$(ssm_read_kind 0 0)" = present ]
[ "$(ssm_read_kind 254 'ParameterNotFound: missing')" = absent ]
[ "$(ssm_read_kind 1 'AccessDeniedException')" = error ]
[ "$(ssm_read_kind 124 'timed out')" = error ]
echo "OK join gate decision table: absent waits, zero never opens CP-0, invalid/unreadable fails, valid predecessor opens"
