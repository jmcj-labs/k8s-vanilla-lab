#!/usr/bin/env bash
# TRANSPORT BUDGET GATE -- permanent, and it stays even when the stubs measure
# 2 KB (INCIDENTS #25).
#
# EC2 rejects user_data above 16384 bytes at RunInstances. `tofu plan` never
# reaches RunInstances, so CI could not see it: the fifth apply died there with
# the founder at 16704 B, 95 bytes of headroom having been spent by a 60-line
# addition nobody measured. Reviewers' memory is not a budget gate.
#
# Measured the way the provider actually builds it -- multipart MIME, gzip,
# base64 -- via the cloudinit provider itself, not a re-implementation.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIMIT_EC2=16384
GATE=${USER_DATA_GATE:-14336}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Values as long as the real ones, so the measurement is not optimistic:
# a real NLB DNS name and a real-length target-group ARN.
DNS="k8s-vanilla-lab-gw-nlb-4e2aa7c9f7618bbb.elb.eu-west-1.amazonaws.com"
TGARN="arn:aws:elasticloadbalancing:eu-west-1:487985088962:targetgroup/k8s-vanilla-lab-api-tg/4e2aa7c9f7618bbb"
BUCKET="k8s-vanilla-lab-backups-487985088962"
PREFIX="bootstrap/k8s-vanilla-lab"
SHA="0000000000000000000000000000000000000000000000000000000000000000"

cat > "$TMP/main.tf" <<EOF
terraform {
  required_providers {
    cloudinit = {
      source = "hashicorp/cloudinit"
    }
  }
}

locals {
  stub_founder = templatefile("$ROOT/bootstrap/stub.yaml", {
    log_file           = "/var/log/k8s-cp-bootstrap.log"
    aws_region         = "eu-west-1"
    s3_uri             = "s3://$BUCKET/$PREFIX/02-control-plane-init.sh"
    sha256             = "$SHA"
    dest               = "/opt/k8s-bootstrap/02-control-plane-init.sh"
    fetch_exec_library = file("$ROOT/bootstrap/fetch-exec.sh")
  })
  stub_join = templatefile("$ROOT/bootstrap/stub.yaml", {
    log_file           = "/var/log/k8s-cp-bootstrap.log"
    aws_region         = "eu-west-1"
    s3_uri             = "s3://$BUCKET/$PREFIX/03-control-plane-join-0.sh"
    sha256             = "$SHA"
    dest               = "/opt/k8s-bootstrap/03-control-plane-join.sh"
    fetch_exec_library = file("$ROOT/bootstrap/fetch-exec.sh")
  })
  common = file("$ROOT/bootstrap/common.yaml")
  worker = templatefile("$ROOT/bootstrap/worker.yaml", {
    cluster_name          = "k8s-vanilla-lab"
    aws_region            = "eu-west-1"
    ssm_join_token_path   = "/k8s/k8s-vanilla-lab/join-command"
    ssm_ca_cert_hash_path = "/k8s/k8s-vanilla-lab/ca-cert-hash"
  })
}

# Profile 1: control plane index 0 -- common + founder stub + join stub.
data "cloudinit_config" "cp0" {
  gzip          = true
  base64_encode = true
  part {
    content_type = "text/x-shellscript"
    content      = local.common
    filename     = "01-common.sh"
  }
  part {
    content_type = "text/x-shellscript"
    content      = local.stub_founder
    filename     = "02-control-plane-init.sh"
  }
  part {
    content_type = "text/x-shellscript"
    content      = local.stub_join
    filename     = "03-control-plane-join.sh"
  }
}

# Profile 2: control plane index 1..N -- common + join stub.
data "cloudinit_config" "cpn" {
  gzip          = true
  base64_encode = true
  part {
    content_type = "text/x-shellscript"
    content      = local.common
    filename     = "01-common.sh"
  }
  part {
    content_type = "text/x-shellscript"
    content      = local.stub_join
    filename     = "03-control-plane-join.sh"
  }
}

# Profile 3: worker -- common + worker, still inline by choice.
data "cloudinit_config" "worker" {
  gzip          = true
  base64_encode = true
  part {
    content_type = "text/x-shellscript"
    content      = local.common
    filename     = "01-common.sh"
  }
  part {
    content_type = "text/x-shellscript"
    content      = local.worker
    filename     = "02-worker.sh"
  }
}

output "cp0" {
  value = data.cloudinit_config.cp0.rendered
}
output "cpn" {
  value = data.cloudinit_config.cpn.rendered
}
output "worker" {
  value = data.cloudinit_config.worker.rendered
}
EOF

export TF_DATA_DIR="$TMP/.tfdata"
( cd "$TMP" && tofu init -backend=false -input=false >/dev/null && tofu apply -auto-approve >/dev/null )

echo "=== presupuesto de transporte de user_data ==="
echo "    gate ${GATE} B  |  limite duro de EC2 ${LIMIT_EC2} B"
FAILED=0
for PROFILE in cp0 cpn worker; do
  B64=$( cd "$TMP" && tofu output -raw "$PROFILE" )
  SIZE=$(printf '%s' "$B64" | base64 -d | wc -c | tr -d ' ')
  if [ "$SIZE" -gt "$GATE" ]; then
    printf "  FAIL %-7s %6d B  excede el gate en %d B\n" "$PROFILE" "$SIZE" "$(( SIZE - GATE ))"
    FAILED=$(( FAILED + 1 ))
  else
    printf "  OK   %-7s %6d B  margen %+d\n" "$PROFILE" "$SIZE" "$(( GATE - SIZE ))"
  fi
done

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "user_data por encima del presupuesto en ${FAILED} perfil(es)."
  echo "No se raspan bytes: lo que crece se mueve al transporte de S3 (INCIDENTS #25)."
  exit 1
fi
echo "OK los tres perfiles de user_data caben en el presupuesto"
