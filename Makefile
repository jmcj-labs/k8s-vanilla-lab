SHELL        := bash
.SHELLFLAGS  := -euo pipefail -c

CLUSTER_NAME    ?= k8s-vanilla-lab
AWS_REGION      ?= eu-west-1
EXPECTED_NODES  ?= 6
TOFU_DIR        := tofu/envs/lab
KUBECONFIG_PATH ?= $(HOME)/.kube/k8s-vanilla-lab.conf

# The CLI-based targets call plain `aws` — resolved from the environment.
# Locally that silently fell through to the stale `default` profile when
# AWS_PROFILE was not exported ("Token has expired" with no owner, twice in
# one day — troubleshooting.md). Default it to the documented lab profile
# LOCALLY ONLY: in CI (GITHUB_ACTIONS set) credentials come from OIDC env
# vars and no named profile exists, so the default must not apply there.
ifndef GITHUB_ACTIONS
AWS_PROFILE ?= k8s-vanilla-lab
export AWS_PROFILE
endif

.DEFAULT_GOAL := help

.PHONY: help check-aws init validate fmt plan apply destroy \
        plan-empty kubeconfig kubeconfig-admin kubeconfig-dev platform smoke-test \
        smoke-app-contract ssm-cp ssm-worker clean bootstrap-aws test

# Preflight for every target that talks to AWS via the CLI: fail fast and
# NAME the credential chain in use instead of leaking a bare
# "Token has expired" from three commands deep.
check-aws:
	@aws sts get-caller-identity >/dev/null 2>&1 || { \
	  echo "✗ AWS credentials unusable (profile: $${AWS_PROFILE:-<default>})"; \
	  echo "  fix: aws sso login --profile $${AWS_PROFILE:-k8s-vanilla-lab}"; \
	  echo "  (per-target credential table: docs/CLUSTER.md §4)"; \
	  exit 1; }

# ── Meta ─────────────────────────────────────────────────────────────────────

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ── OpenTofu ──────────────────────────────────────────────────────────────────

init: ## Initialise OpenTofu with backend config (requires tofu/envs/lab/backend.hcl)
	cd $(TOFU_DIR) && tofu init -backend-config=backend.hcl

validate: ## Check formatting and validate all stacks (no backend required)
	@tofu fmt -check -recursive tofu/; \
	for STACK in tofu/envs/lab tofu/envs/identity; do \
	  VALIDATE_TMP=$$(mktemp -d); \
	  echo "── validating $$STACK ──"; \
	  ( cd "$$STACK" && \
	    TF_DATA_DIR="$$VALIDATE_TMP" tofu init -backend=false -input=false >/dev/null && \
	    TF_DATA_DIR="$$VALIDATE_TMP" tofu validate ) || { rm -rf "$$VALIDATE_TMP"; exit 1; }; \
	  rm -rf "$$VALIDATE_TMP"; \
	done

test: ## Run the script test suites that need no cluster and no AWS
	@bash scripts/test-bootstrap-ascii.sh
	@echo ""
	@bash scripts/test-bootstrap-join-gate.sh
	@echo ""
	@bash scripts/test-smoke-envoy-e2e.sh
	@echo ""
	@bash scripts/test-witness-verdict.sh
	@echo ""
	@bash scripts/test-witness-liveness.sh
	@echo ""
	@bash scripts/test-gateway-canary-logic.sh
	@echo ""
	@bash scripts/test-4b-flow.sh
	@echo ""
	@bash scripts/test-crd-diff-gate.sh
	@echo ""
	@bash scripts/test-cilium-schema-gate.sh
	@echo ""
	@bash scripts/test-kpr-parser.sh
	@echo ""
	@bash scripts/test-kpr-gate.sh
	@echo ""
	@bash scripts/test-fetch-exec.sh
	@echo ""
	@if command -v go >/dev/null 2>&1; then \
	  echo "=== node-readiness (Go) ==="; \
	  (cd platform/node-readiness && go test ./...); \
	else \
	  echo "=== node-readiness (Go) ==="; \
	  echo "  OMITIDO: go ausente. Esto NO es un pase — es un no-ejecutado."; \
	  exit 1; \
	fi

user-data-size: ## Measure real user_data (gzip+base64) for the three profiles and fail above budget
	@bash scripts/check-user-data-size.sh

plan-empty: ## Plan the lab stack against an EMPTY state (catches count/for_each on known-after-apply — INCIDENTS #11)
	@STACK=tofu/envs/lab; \
	EMPTY_DATA=$$(mktemp -d); \
	OVERRIDE="$$STACK/zz_empty_state_override.tf"; \
	printf 'terraform {\n  backend "local" {}\n}\n' > "$$OVERRIDE"; \
	trap 'rm -f "$$OVERRIDE"; rm -rf "$$EMPTY_DATA"' EXIT; \
	( cd "$$STACK" && \
	  TF_DATA_DIR="$$EMPTY_DATA" tofu init -input=false >/dev/null && \
	  TF_DATA_DIR="$$EMPTY_DATA" tofu plan -input=false -no-color \
	    -var="lab_account_id=" \
	    -var="ssh_key_name=plan-empty" -var="aws_profile=$(AWS_PROFILE)" ) \
	  || { echo "✗ plan-from-empty failed — a count/for_each likely depends on a known-after-apply value (INCIDENTS #11)"; exit 1; }

fmt: ## Format all .tf files recursively
	tofu fmt -recursive tofu/

plan: ## Show execution plan (requires init)
	cd $(TOFU_DIR) && tofu plan

apply: ## Apply infrastructure changes (auto-approve)
	@TOFU_DIR=$(TOFU_DIR) bash scripts/guard-legacy-cp-state.sh
	cd $(TOFU_DIR) && tofu apply -auto-approve

destroy: ## Destroy all infrastructure (auto-approve)
	cd $(TOFU_DIR) && tofu destroy -auto-approve

# ── Cluster access ────────────────────────────────────────────────────────────

kubeconfig-admin: check-aws ## IAM-auth kubeconfig (platform-admin role) → ~/.kube/k8s-vanilla-lab-admin.conf
	@CLUSTER_NAME=$(CLUSTER_NAME) AWS_REGION=$(AWS_REGION) \
	  bash scripts/iam-kubeconfig.sh admin $(HOME)/.kube/k8s-vanilla-lab-admin.conf

kubeconfig-dev: check-aws ## IAM-auth kubeconfig (developer role, ns logistics) → ~/.kube/k8s-vanilla-lab-dev.conf
	@CLUSTER_NAME=$(CLUSTER_NAME) AWS_REGION=$(AWS_REGION) \
	  bash scripts/iam-kubeconfig.sh dev $(HOME)/.kube/k8s-vanilla-lab-dev.conf

kubeconfig: check-aws ## BREAK-GLASS admin kubeconfig from SSM (static cert — daily use is kubeconfig-admin)
	@aws ssm get-parameter \
	  --name "/k8s/$(CLUSTER_NAME)/kubeconfig" \
	  --with-decryption \
	  --query Parameter.Value \
	  --output text \
	  --region $(AWS_REGION) > $(KUBECONFIG_PATH)
	@chmod 600 $(KUBECONFIG_PATH)
	@echo "✓ Kubeconfig saved to $(KUBECONFIG_PATH)"
	@echo ""
	@echo "  export KUBECONFIG=$(KUBECONFIG_PATH)"

platform: check-aws ## Install platform layer (EBS CSI, cert-manager, Gateway, operators, monitoring)
	@KUBECONFIG_FILE=$$(mktemp); \
	trap 'rm -f "$$KUBECONFIG_FILE"' EXIT; \
	if ! aws ssm get-parameter \
	  --name "/k8s/$(CLUSTER_NAME)/kubeconfig" \
	  --with-decryption \
	  --query Parameter.Value \
	  --output text \
	  --region $(AWS_REGION) > "$$KUBECONFIG_FILE"; then \
	  echo "✗ Failed to fetch kubeconfig from SSM (check AWS credentials and profile)"; \
	  exit 1; \
	fi; \
	chmod 600 "$$KUBECONFIG_FILE"; \
	KUBECONFIG="$$KUBECONFIG_FILE" AWS_REGION=$(AWS_REGION) CLUSTER_NAME=$(CLUSTER_NAME) bash platform/install.sh

smoke-test: check-aws ## Verify cluster + platform (nodes, KPR, providerID, PVC, Gateway, operators)
	@KUBECONFIG_FILE=$$(mktemp); \
	trap 'rm -f "$$KUBECONFIG_FILE"' EXIT; \
	if ! aws ssm get-parameter \
	  --name "/k8s/$(CLUSTER_NAME)/kubeconfig" \
	  --with-decryption \
	  --query Parameter.Value \
	  --output text \
	  --region $(AWS_REGION) > "$$KUBECONFIG_FILE"; then \
	  echo "✗ Failed to fetch kubeconfig from SSM (check AWS credentials and profile)"; \
	  exit 1; \
	fi; \
	if [ ! -s "$$KUBECONFIG_FILE" ]; then \
	  echo "✗ Kubeconfig is empty — SSM fetch may have failed silently"; \
	  exit 1; \
	fi; \
	chmod 600 "$$KUBECONFIG_FILE"; \
	KUBECONFIG="$$KUBECONFIG_FILE" EXPECTED_NODES=$(EXPECTED_NODES) \
	  CLUSTER_NAME=$(CLUSTER_NAME) AWS_REGION=$(AWS_REGION) \
	  bash scripts/smoke-test.sh

smoke-app-contract: check-aws ## Verify the deployed app against the platform contract (run AFTER Repo 2 deploys; needs GITHUB_SHA)
	@KUBECONFIG_FILE=$$(mktemp); \
	trap 'rm -f "$$KUBECONFIG_FILE"' EXIT; \
	aws ssm get-parameter --name "/k8s/$(CLUSTER_NAME)/kubeconfig" --with-decryption \
	  --query Parameter.Value --output text --region $(AWS_REGION) > "$$KUBECONFIG_FILE" \
	  || { echo "✗ Failed to fetch kubeconfig from SSM"; exit 1; }; \
	chmod 600 "$$KUBECONFIG_FILE"; \
	KUBECONFIG="$$KUBECONFIG_FILE" CLUSTER_NAME=$(CLUSTER_NAME) AWS_REGION=$(AWS_REGION) \
	  bash scripts/smoke-app-contract.sh

# Out-of-band shell — SSM Session Manager, NOT ssh (INCIDENTS #16).
# There is no inbound SSH any more and no private key to lose: access rides
# on the instance profile and every session is recorded in CloudTrail.
# The session lands as `ssm-user` (passwordless sudo available); Run
# Command, used by the ceremonies, runs as root directly.
# Needs the session-manager-plugin locally:
#   brew install --cask session-manager-plugin
#   (or the no-sudo bundle: https://s3.amazonaws.com/session-manager-downloads/plugin/latest/)
ssm-cp: check-aws ## Interactive shell on a control plane (CP_INDEX=0|1|2, default 0)
	@IID=$$(aws ec2 describe-instances --region $(AWS_REGION) \
	  --filters "Name=tag:kubernetes.io/cluster/$(CLUSTER_NAME),Values=owned" \
	            "Name=tag:Role,Values=control-plane" \
	            "Name=tag:CPIndex,Values=$(or $(CP_INDEX),0)" \
	            "Name=instance-state-name,Values=running" \
	  --query 'Reservations[].Instances[].InstanceId' --output text); \
	[ -n "$$IID" ] || { echo "✗ no control plane with CPIndex=$(or $(CP_INDEX),0)"; exit 1; }; \
	echo "→ session on $$IID (control plane $(or $(CP_INDEX),0))"; \
	aws ssm start-session --target "$$IID" --region $(AWS_REGION)

ssm-worker: check-aws ## Interactive shell on a worker (WORKER_INDEX=1..N, default 1)
	@IID=$$(aws ec2 describe-instances --region $(AWS_REGION) \
	  --filters "Name=tag:kubernetes.io/cluster/$(CLUSTER_NAME),Values=owned" \
	            "Name=tag:WorkerIndex,Values=$(or $(WORKER_INDEX),1)" \
	            "Name=instance-state-name,Values=running" \
	  --query 'Reservations[].Instances[].InstanceId' --output text); \
	[ -n "$$IID" ] || { echo "✗ no worker with WorkerIndex=$(or $(WORKER_INDEX),1)"; exit 1; }; \
	echo "→ session on $$IID (worker $(or $(WORKER_INDEX),1))"; \
	aws ssm start-session --target "$$IID" --region $(AWS_REGION)

# ── Utility ───────────────────────────────────────────────────────────────────

clean: ## Remove local OpenTofu cache and backup files
	rm -rf $(TOFU_DIR)/.terraform $(TOFU_DIR)/tfplan
	find . -name "*.tfstate.backup" -delete

# ── One-time setup ────────────────────────────────────────────────────────────

bootstrap-aws: ## Create/verify S3 state bucket, DynamoDB lock table, OIDC provider, IAM role
	CLUSTER_NAME=$(CLUSTER_NAME) AWS_REGION=$(AWS_REGION) bash scripts/bootstrap-aws.sh
