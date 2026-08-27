#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

assert_ascii() {
  local file="$1"
  if LC_ALL=C od -An -tu1 -v "$file" | awk '{for(i=1;i<=NF;i++) if($i>127) exit 1}'; then
    return 0
  fi
  echo "ERROR non-ASCII byte in $file" >&2
  return 1
}

for file in "$ROOT"/bootstrap/*.yaml "$ROOT"/bootstrap/*.sh; do
  assert_ascii "$file"
  bash -n "$file"
done

render() {
  local expression="$1" destination="$2"
  tofu -chdir="$TMP" console <<< "base64encode($expression)" \
    | tr -d '"\n' | base64 -d > "$destination"
  assert_ascii "$destination"
  bash -n "$destination"
}

COMMON='cluster_name="k8s-vanilla-lab",aws_region="eu-west-1",api_endpoint_dns="example.invalid",ssm_parameter_path="/k8s/k8s-vanilla-lab"'
render "templatefile(\"$ROOT/bootstrap/control-plane.yaml\",{$COMMON,pod_cidr=\"10.244.0.0/16\",service_cidr=\"10.96.0.0/12\",api_target_group_arn=\"arn:aws:elasticloadbalancing:eu-west-1:111122223333:targetgroup/api/123\"})" "$TMP/founder.sh"
render "templatefile(\"$ROOT/bootstrap/control-plane-join.yaml\",{$COMMON,cp_index=1,cp_count=3,joined_count_library=file(\"$ROOT/bootstrap/joined-count.sh\")})" "$TMP/join.sh"
render "templatefile(\"$ROOT/bootstrap/worker.yaml\",{cluster_name=\"k8s-vanilla-lab\",aws_region=\"eu-west-1\",ssm_join_token_path=\"/k8s/k8s-vanilla-lab/join-command\",ssm_ca_cert_hash_path=\"/k8s/k8s-vanilla-lab/ca-cert-hash\"})" "$TMP/worker.sh"

printf '\303\263' > "$TMP/non-ascii"
if assert_ascii "$TMP/non-ascii" 2>/dev/null; then
  echo "ERROR ASCII gate accepted a non-ASCII fixture" >&2
  exit 1
fi
echo "OK bootstrap source and exact templatefile outputs are ASCII-only and parse as Bash"
