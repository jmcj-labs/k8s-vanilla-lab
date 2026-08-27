variable "name" {
  description = "Name identifier for control plane resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where control plane will be deployed"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID for control plane instance"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for control plane"
  type        = string
  default     = "t3.medium"
}

variable "ami_id" {
  description = "AMI ID for Ubuntu 24.04 LTS"
  type        = string
}

variable "key_name" {
  description = "SSH key pair name for instance access"
  type        = string
}

variable "control_plane_count" {
  description = "STATIC control-plane node count (3 for HA, stacked etcd — quorum needs an odd number). Drives instance count and must never depend on a computed value (INCIDENTS #11)."
  type        = number
  default     = 3
  validation {
    condition     = var.control_plane_count % 2 == 1
    error_message = "control_plane_count must be odd (etcd quorum)"
  }
}

variable "user_data_base64" {
  description = "Base64-encoded (gzipped) cloud-init user data per control-plane node, by index (index 0 = kubeadm init, rest = sequential control-plane joins). Length must match control_plane_count."
  type        = list(string)
}

variable "nlb_security_group_id" {
  description = "NLB's security group — the ONLY source the API :6443 accepts (ADR-007)"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}

variable "root_volume_size" {
  description = "Root volume size in GB"
  type        = number
  default     = 30
}

variable "root_volume_type" {
  description = "Root volume type (gp3 recommended)"
  type        = string
  default     = "gp3"
}

variable "cluster_name" {
  description = "Kubernetes cluster name for token storage in SSM"
  type        = string
}

variable "enable_etcd_backup_policy" {
  description = "Grant the CP instance role write access to the etcd/ prefix of the backups bucket (S2 piece 1). Static bool on purpose — count must never depend on a computed value (INCIDENTS #11)."
  type        = bool
  default     = true
}

variable "bootstrap_bucket_name" {
  description = "Bucket holding the bootstrap script objects the first-boot stub fetches (INCIDENTS #25). Same persistent bucket; the objects are owned by the lab stack."
  type        = string
}

variable "bootstrap_prefix" {
  description = "Key prefix of this cluster's bootstrap objects. The GetObject grant is scoped to it, never to the whole bucket."
  type        = string
}

variable "backup_bucket_name" {
  description = "Name of the persistent backups bucket (tofu/envs/persistent). Only used to build the etcd/ policy Resource strings."
  type        = string
  default     = ""
}
