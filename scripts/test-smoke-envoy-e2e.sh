#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib/envoy-e2e-verdict.sh
. "$ROOT/scripts/lib/envoy-e2e-verdict.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf 'HTTP/2 404\r\nserver: envoy\r\n\r\n' > "$TMP/envoy"
printf 'HTTP/2 404\r\nserver: nginx\r\n\r\n' > "$TMP/nginx"
: > "$TMP/empty"

envoy_e2e_verdict 200 "$TMP/empty"
envoy_e2e_verdict 404 "$TMP/envoy"
! envoy_e2e_verdict 404 "$TMP/nginx"
! envoy_e2e_verdict 404 "$TMP/empty"
! envoy_e2e_verdict 000 "$TMP/empty"
! envoy_e2e_verdict 503 "$TMP/envoy"
echo "OK envoy e2e verdict: 200 accepted; 404 requires Server: envoy; transport/other failures rejected"
