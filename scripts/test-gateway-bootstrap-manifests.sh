#!/usr/bin/env bash
# Validates the Gateway API CRDs the founder will apply — against the files
# VENDORED IN THIS REPO, not against raw.githubusercontent.com.
#
# INCIDENTS #27: those seven downloads used to happen here and on the node.
# GitHub returned 400 for one of them at a tag where the file demonstrably
# existed, which killed the founder. Fetching them here would keep a third
# party in the path of CI as well, and would validate bytes that are not
# necessarily the bytes the founder applies.
#
# What this asserts is the pair: the files are the right CRDs, AND their
# digests are the ones tofu will bake into the founder. A test that checked
# only the content would pass while the node applied something else.
set -euo pipefail

command -v ruby >/dev/null 2>&1 || { echo "ERROR ruby is required to parse CRD YAML" >&2; exit 1; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=v1.6.1
DIR="${ROOT}/bootstrap/gateway-api/${VERSION}"
MANIFEST="${DIR}/MANIFEST"

[ -d "${DIR}" ] || { echo "ERROR vendored CRDs missing at ${DIR}" >&2; exit 1; }
[ -f "${MANIFEST}" ] || { echo "ERROR provenance MANIFEST missing at ${MANIFEST}" >&2; exit 1; }

KINDS="gatewayclasses gateways httproutes grpcroutes referencegrants backendtlspolicies"

# TLSRoute belongs to the experimental overlay and to nothing else, in either
# direction: absent from the six standard files, present in the overlay.
for kind in ${KINDS}; do
  f="${DIR}/gateway.networking.k8s.io_${kind}.yaml"
  [ -f "${f}" ] || { echo "ERROR missing vendored ${kind}" >&2; exit 1; }
  if grep -q 'kind: TLSRoute' "${f}"; then
    echo "ERROR standard ${kind} contains TLSRoute" >&2; exit 1
  fi
done
grep -q 'kind: TLSRoute' "${DIR}/gateway.networking.k8s.io_tlsroutes.yaml" \
  || { echo "ERROR experimental overlay does not contain TLSRoute" >&2; exit 1; }

# The digests recorded in MANIFEST must still be the digests of the files. This
# is what ties the review to what ships: without it, editing a vendored CRD
# would silently change what the founder applies.
while read -r _kind _channel _gitsha want_sha _bytes; do
  case "${_kind}" in ''|\#*) continue ;; esac
  f="${DIR}/gateway.networking.k8s.io_${_kind}.yaml"
  got_sha=$(sha256sum "${f}" | awk '{print $1}')
  if [ "${got_sha}" != "${want_sha}" ]; then
    echo "ERROR ${_kind}: MANIFEST says ${want_sha}, file is ${got_sha}" >&2
    exit 1
  fi
done < "${MANIFEST}"

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
' "${DIR}"

echo "OK Gateway API v1.6.1 vendored: 7 CRDs, digests match MANIFEST, TLSRoute only in the overlay, bundle exact — no network"
