SHELL        := bash
.SHELLFLAGS  := -euo pipefail -c

CLUSTER_NAME    ?= k8s-vanilla-lab
AWS_REGION      ?= eu-west-1
TOFU_DIR        := tofu/envs/lab
KUBECONFIG_PATH ?= $(HOME)/.kube/k8s-vanilla-lab.conf
SSH_KEY_PATH    ?= $(HOME)/.ssh/k8s-vanilla-lab.pem
SSH_USER        := ubuntu

.DEFAULT_GOAL := help

.PHONY: help init validate fmt plan apply destroy \
        kubeconfig smoke-test ssh-cp ssh-worker \
        clean bootstrap-aws

# ── Meta ─────────────────────────────────────────────────────────────────────

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ── OpenTofu ──────────────────────────────────────────────────────────────────

init: ## Initialise OpenTofu with backend config (requires tofu/envs/lab/backend.hcl)
	cd $(TOFU_DIR) && tofu init -backend-config=backend.hcl

validate: ## Check formatting and validate configuration (no backend required)
	@VALIDATE_TMP=$$(mktemp -d); \
	trap 'rm -rf "$$VALIDATE_TMP"' EXIT; \
	tofu fmt -check -recursive tofu/ && \
	  cd $(TOFU_DIR) && TF_DATA_DIR="$$VALIDATE_TMP" tofu init -backend=false -input=false && \
	  TF_DATA_DIR="$$VALIDATE_TMP" tofu validate

fmt: ## Format all .tf files recursively
	tofu fmt -recursive tofu/

plan: ## Show execution plan (requires init)
	cd $(TOFU_DIR) && tofu plan

apply: ## Apply infrastructure changes (auto-approve)
	cd $(TOFU_DIR) && tofu apply -auto-approve

destroy: ## Destroy all infrastructure (auto-approve)
	cd $(TOFU_DIR) && tofu destroy -auto-approve

# ── Cluster access ────────────────────────────────────────────────────────────

kubeconfig: ## Fetch kubeconfig from SSM and save to KUBECONFIG_PATH
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

smoke-test: ## Verify all nodes are Ready (kubeconfig fetched from SSM, not persisted to disk)
	@KUBECONFIG_FILE=$$(mktemp); \
	trap 'rm -f "$$KUBECONFIG_FILE"' EXIT; \
	if ! aws ssm get-parameter \
	  --name "/k8s/$(CLUSTER_NAME)/kubeconfig" \
	  --with-decryption \
	  --query Parameter.Value \
	  --output text \
	  --region $(AWS_REGION) > "$$KUBECONFIG_FILE" 2>&1; then \
	  echo "✗ Failed to fetch kubeconfig from SSM (check AWS credentials and profile)"; \
	  exit 1; \
	fi; \
	if [ ! -s "$$KUBECONFIG_FILE" ]; then \
	  echo "✗ Kubeconfig is empty — SSM fetch may have failed silently"; \
	  exit 1; \
	fi; \
	chmod 600 "$$KUBECONFIG_FILE"; \
	echo "Cluster nodes:"; \
	KUBECONFIG="$$KUBECONFIG_FILE" kubectl get nodes; \
	NOT_READY=$$(KUBECONFIG="$$KUBECONFIG_FILE" kubectl get nodes --no-headers \
	  | awk '$$2 != "Ready" {n++} END {print n+0}'); \
	if [ "$$NOT_READY" -gt 0 ]; then \
	  echo "✗ $$NOT_READY node(s) not Ready"; \
	  exit 1; \
	fi; \
	echo "✓ All nodes Ready"

ssh-cp: ## SSH into the control plane node
	ssh -i $(SSH_KEY_PATH) -o StrictHostKeyChecking=no \
	  $(SSH_USER)@$$(cd $(TOFU_DIR) && tofu output -raw control_plane_public_ip)

ssh-worker: ## SSH into the first worker node
	ssh -i $(SSH_KEY_PATH) -o StrictHostKeyChecking=no \
	  $(SSH_USER)@$$(cd $(TOFU_DIR) && tofu output -json worker_public_ips | jq -r '.[0]')

# ── Utility ───────────────────────────────────────────────────────────────────

clean: ## Remove local OpenTofu cache and backup files
	rm -rf $(TOFU_DIR)/.terraform $(TOFU_DIR)/tfplan
	find . -name "*.tfstate.backup" -delete

# ── One-time setup ────────────────────────────────────────────────────────────

bootstrap-aws: ## Create/verify S3 state bucket, DynamoDB lock table, OIDC provider, IAM role
	CLUSTER_NAME=$(CLUSTER_NAME) AWS_REGION=$(AWS_REGION) bash scripts/bootstrap-aws.sh
