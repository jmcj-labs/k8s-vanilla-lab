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

variable "my_ip" {
  description = "CIDR allowed for SSH and K8s API access (no default — must be passed by the caller)"
  type        = string
  validation {
    condition     = can(cidrhost(var.my_ip, 0))
    error_message = "Must be a valid CIDR block (e.g., 1.2.3.4/32 or 0.0.0.0/0)"
  }
}

variable "user_data_base64" {
  description = "Base64-encoded (gzipped) cloud-init user data for control plane bootstrap (cloudinit_config with gzip + base64_encode)"
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

variable "api_server_allowed_cidrs" {
  description = "CIDR blocks allowed to access Kubernetes API server (6443). Defaults to my_ip for security."
  type        = list(string)
  default     = []
  validation {
    condition = alltrue([
      for cidr in var.api_server_allowed_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "All entries must be valid CIDR blocks (e.g., 1.2.3.4/32)"
  }
}

variable "enable_etcd_backup_policy" {
  description = "Grant the CP instance role write access to the etcd/ prefix of the backups bucket (S2 piece 1). Static bool on purpose — count must never depend on a computed value (INCIDENTS #11)."
  type        = bool
  default     = true
}

variable "backup_bucket_name" {
  description = "Name of the persistent backups bucket (tofu/envs/persistent). Only used to build the etcd/ policy Resource strings."
  type        = string
  default     = ""
}
