variable "lab_account_id" {
  description = "AWS account ID of the lab member account. Required: the allowed_account_ids guard must fail fast on wrong credentials — backups are the one thing a mis-targeted apply must never touch. Supply via terraform.tfvars (never versioned)."
  type        = string
}

variable "aws_region" {
  description = "Region for the backups bucket — same as the cluster (restore pulls are intra-region, no egress cost)."
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "Local AWS profile with lab-account credentials. This stack is only ever applied locally."
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "Cluster name — used in the default bucket name and the IAM user name."
  type        = string
  default     = "k8s-vanilla-lab"
}

variable "bucket_name" {
  description = "Name of the backups bucket. Empty derives '<cluster_name>-backups-<account_id>' (globally unique, no hardcoded IDs in Git). The cluster stack consumes the same default — keep them in sync if overridden."
  type        = string
  default     = ""
}

variable "etcd_retention_days" {
  description = "Days before etcd/ snapshots (current and noncurrent versions) expire."
  type        = number
  default     = 7
}

variable "cnpg_retention_days" {
  description = "Days before cnpg/ objects (current and noncurrent versions) expire. Keep coherent with the barman retentionPolicy in platform/data/cnpg-cluster.yaml."
  type        = number
  default     = 14
}
