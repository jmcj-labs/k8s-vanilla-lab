variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
  default     = "k8s-vanilla-lab"
}

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Environment name (lab, dev, prod)"
  type        = string
  default     = "lab"
}

variable "control_plane_count" {
  # 3 control planes, stacked etcd, ONE AZ: this is NODE HA (survives losing
  # a CP), not zonal HA — zonal is declared post-S2 debt (ADR-007).
  description = "Number of control-plane nodes (odd, for etcd quorum). The API endpoint is the NLB's DNS on TCP/6443."
  type        = number
  default     = 3
}

variable "worker_count" {
  # 3, not 2: real anti-affinity for the phase-2 data topology
  # (CNPG x3 instances, Kafka x3 brokers — one per worker).
  description = "Number of worker nodes"
  type        = number
  default     = 3
}

variable "ssh_key_name" {
  description = "Name of existing AWS SSH key pair"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "control_plane_instance_type" {
  description = "Instance type for control plane"
  type        = string
  default     = "t3.medium"
}

variable "worker_instance_type" {
  description = "Instance type for workers"
  type        = string
  default     = "t3.medium"
}

variable "worker_capacity_type" {
  description = "Worker capacity type: spot or on-demand"
  type        = string
  default     = "spot"
  validation {
    condition     = contains(["spot", "on-demand"], var.worker_capacity_type)
    error_message = "Must be 'spot' or 'on-demand'"
  }
}

variable "project" {
  description = "Project name for tagging"
  type        = string
  default     = "k8s-vanilla-lab"
}

variable "owner" {
  description = "Owner name for tagging"
  type        = string
  default     = "platform-engineering"
}

variable "lab_account_id" {
  description = "AWS account ID of the lab member account. Supply via terraform.tfvars (never versioned) or TF_VAR_lab_account_id / the LAB_ACCOUNT_ID GitHub Variable in CI. Empty skips the account guard."
  type        = string
  default     = ""
}

variable "aws_profile" {
  description = "AWS CLI profile for local authentication. Leave empty in CI (OIDC sets credentials via environment variables)."
  type        = string
  default     = ""
}

variable "backup_bucket_name" {
  description = "Name of the persistent backups bucket (tofu/envs/persistent — separate lifecycle, applied manually). Empty derives '<cluster_name>-backups-<account_id>', the same default the persistent stack uses. Consumed by variable on purpose: no remote-state coupling between the graphs."
  type        = string
  default     = ""
}

variable "gateway_nodeport" {
  description = "Deterministic NodePort of the Gateway Service — single source of truth (Tofu). install.sh reconciles the live Service to it; the NLB target group and the worker SG rule consume it. Change here and everything follows."
  type        = number
  default     = 30443
}
