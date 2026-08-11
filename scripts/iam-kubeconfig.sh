#!/usr/bin/env bash
# Generate an IAM-auth kubeconfig (exec → aws-iam-authenticator token).
#
# Usage: iam-kubeconfig.sh <admin|dev> <output-path>
# Env:   CLUSTER_NAME, AWS_REGION (defaults below), AWS_PROFILE respected.
#
# The OUTPUT contains no Kubernetes credentials at all — only the cluster
# endpoint, its (public) CA and an exec block. Generating it needs
# platform-level AWS permissions (reads the break-glass kubeconfig in SSM
# for endpoint+CA); the generated file can safely be handed to a developer.
set -euo pipefail

PROFILE_TYPE="${1:?usage: iam-kubeconfig.sh <admin|dev> <output-path>}"
OUT="${2:?usage: iam-kubeconfig.sh <admin|dev> <output-path>}"
CLUSTER_NAME="${CLUSTER_NAME:-k8s-vanilla-lab}"
AWS_REGION="${AWS_REGION:-eu-west-1}"

# Pinned client (CLUSTER.md version table). Checksums from the official
# release file authenticator_0.7.18_checksums.txt.
IAM_AUTH_VERSION="0.7.18"
SHA_LINUX_AMD64="fbebd5350dd1a5f377097fd1b2e1ca8c5a5e7ecb35cc44ddc694b775d498d7a5"
SHA_DARWIN_ARM64="3704767c72ab56676ea1e398aa90ea42a53b0a9bd215a0babfae8e86bb21cf95"

case "${PROFILE_TYPE}" in
  admin) ROLE_NAME="${CLUSTER_NAME}-platform-admin" ;;
  dev)   ROLE_NAME="${CLUSTER_NAME}-developer" ;;
  *) echo "✗ unknown profile '${PROFILE_TYPE}' (expected admin|dev)" >&2; exit 1 ;;
esac

BIN=$(command -v aws-iam-authenticator) || {
  echo "✗ aws-iam-authenticator not installed. Pin v${IAM_AUTH_VERSION}:" >&2
  echo "  https://github.com/kubernetes-sigs/aws-iam-authenticator/releases/tag/v${IAM_AUTH_VERSION}" >&2
  exit 1
}

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)  EXPECTED="${SHA_LINUX_AMD64}" ;;
  Darwin/arm64)  EXPECTED="${SHA_DARWIN_ARM64}" ;;
  *)             EXPECTED="" ;;
esac
if [ -n "${EXPECTED}" ]; then
  ACTUAL=$(shasum -a 256 "${BIN}" 2>/dev/null | awk '{print $1}')
  [ -n "${ACTUAL}" ] || ACTUAL=$(sha256sum "${BIN}" | awk '{print $1}')
  if [ "${ACTUAL}" != "${EXPECTED}" ]; then
    echo "✗ installed aws-iam-authenticator is not the pinned v${IAM_AUTH_VERSION} (checksum mismatch)" >&2
    exit 1
  fi
else
  echo "⚠ no pinned checksum for $(uname -s)/$(uname -m) — skipping binary verification" >&2
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
# Same clusterID as bootstrap, platform installer and CI: ACCOUNT.REGION.NAME
CLUSTER_ID="${ACCOUNT_ID}.${AWS_REGION}.${CLUSTER_NAME}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

TMP=$(mktemp)
trap 'rm -f "${TMP}"' EXIT
aws ssm get-parameter \
  --name "/k8s/${CLUSTER_NAME}/kubeconfig" \
  --with-decryption \
  --query Parameter.Value \
  --output text \
  --region "${AWS_REGION}" > "${TMP}"
SERVER=$(KUBECONFIG="${TMP}" kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}')
CA_DATA=$(KUBECONFIG="${TMP}" kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
[ -n "${SERVER}" ] && [ -n "${CA_DATA}" ] || { echo "✗ could not extract endpoint/CA from SSM kubeconfig" >&2; exit 1; }

cat > "${OUT}" <<KUBECONFIG_EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER_NAME}
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA_DATA}
contexts:
  - name: ${CLUSTER_NAME}-${PROFILE_TYPE}
    context:
      cluster: ${CLUSTER_NAME}
      user: iam-${PROFILE_TYPE}
current-context: ${CLUSTER_NAME}-${PROFILE_TYPE}
users:
  - name: iam-${PROFILE_TYPE}
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: aws-iam-authenticator
        # --forward-session-name: the Kubernetes username carries the STS
        # session (who assumed the role), not just the role — traceability.
        args:
          - token
          - -i
          - ${CLUSTER_ID}
          - -r
          - ${ROLE_ARN}
          - --forward-session-name
        interactiveMode: Never
KUBECONFIG_EOF
chmod 600 "${OUT}"

echo "✓ IAM kubeconfig (${PROFILE_TYPE} → ${ROLE_NAME}) written to ${OUT}"
echo ""
echo "  export KUBECONFIG=${OUT}"
echo "  # credentials come from your AWS session at kubectl time:"
echo "  #   aws sso login --profile <k8s-platform|k8s-dev>   (when it expires)"
echo "  #   AWS_PROFILE=<profile> kubectl get pods"
