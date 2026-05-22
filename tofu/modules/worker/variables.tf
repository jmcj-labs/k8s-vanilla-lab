variable "name" {
  description = "Name identifier for worker resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where workers will be deployed"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID for worker instances"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for workers"
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
  description = "Your public IP for SSH access (CIDR format)"
  type        = string
  validation {
    condition     = can(cidrhost(var.my_ip, 0))
    error_message = "Must be a valid CIDR block (e.g., 1.2.3.4/32)"
  }
}

variable "control_plane_security_group_id" {
  description = "Security group ID of control plane (for ingress rules)"
  type        = string
}

variable "user_data" {
  description = "cloud-init user data for worker bootstrap"
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
  description = "Kubernetes cluster name for token retrieval from SSM"
  type        = string
}

variable "worker_count" {
  description = "Number of worker nodes to create"
  type        = number
  default     = 2
  validation {
    condition     = var.worker_count > 0 && var.worker_count <= 10
    error_message = "Worker count must be between 1 and 10"
  }
}

variable "capacity_type" {
  description = "Capacity type: spot (default) or on-demand"
  type        = string
  default     = "spot"
  validation {
    condition     = contains(["spot", "on-demand"], var.capacity_type)
    error_message = "Capacity type must be either 'spot' or 'on-demand'"
  }
}
