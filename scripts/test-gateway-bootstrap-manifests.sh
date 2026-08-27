#!/usr/bin/env bash
set -euo pipefail

command -v ruby >/dev/null 2>&1 || { echo "ERROR ruby is required to parse CRD YAML" >&2; exit 1; }
VERSION=v1.6.1
BASE="https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${VERSION}/config/crd"
KINDS="gatewayclasses gateways httproutes grpcroutes referencegrants backendtlspolicies"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for kind in $KINDS; do
  curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 \
    -o "$TMP/$kind.yaml" "$BASE/standard/gateway.networking.k8s.io_$kind.yaml"
  ! grep -q 'kind: TLSRoute' "$TMP/$kind.yaml"
done
curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 \
  -o "$TMP/tlsroutes.yaml" "$BASE/experimental/gateway.networking.k8s.io_tlsroutes.yaml"
grep -q 'kind: TLSRoute' "$TMP/tlsroutes.yaml"

ruby -ryaml -e '
  dir = ARGV.shift
  expected = %w[backendtlspolicies gatewayclasses gateways grpcroutes httproutes referencegrants tlsroutes]
  files = Dir[File.join(dir, "*.yaml")]
  abort "expected 7 CRDs, got #{files.length}" unless files.length == 7
  files.each do |file|
    crd = YAML.load_file(file)
    short = crd.fetch("metadata").fetch("name").split(".").first
    abort "unexpected CRD #{short}" unless expected.include?(short)
    bundle = crd.dig("metadata", "annotations", "gateway.networking.k8s.io/bundle-version")
    abort "#{short}: bundle #{bundle.inspect}" unless bundle == "v1.6.1"
    served = crd.dig("spec", "versions").select { |v| v["served"] }.map { |v| v["name"] }.sort
    abort "#{short}: v1 not served" unless served.include?("v1")
    if short == "tlsroutes"
      abort "tlsroutes: served #{served.inspect}" unless served == %w[v1 v1alpha2 v1alpha3]
    end
  end
' "$TMP"
echo "OK Gateway API v1.6.1 inputs: six standard CRDs exclude TLSRoute; overlay last serves v1/v1alpha2/v1alpha3; bundle exact"
