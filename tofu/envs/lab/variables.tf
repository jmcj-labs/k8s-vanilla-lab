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

variable "api_server_allowed_cidrs" {
  description = "CIDRs allowed to reach the K8s API (6443). Default 0.0.0.0/0: the API is TLS + cert-authenticated and CI (platform install + smoke test via SSM kubeconfig, ADR-004) runs from GitHub runners with dynamic IPs. SSH stays restricted to my_ip."
  type        = list(string)
  default     = ["0.0.0.0/0"]
  validation {
    condition = alltrue([
      for cidr in var.api_server_allowed_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "All entries must be valid CIDR blocks (e.g., 1.2.3.4/32)"
  }
}

variable "my_ip" {
  description = "CIDR allowed for SSH and K8s API access. No default on purpose: set it explicitly in terraform.tfvars (your IP as x.x.x.x/32, or consciously 0.0.0.0/0)."
  type        = string
  validation {
    condition     = can(cidrhost(var.my_ip, 0))
    error_message = "Must be a valid CIDR block (e.g., 1.2.3.4/32 or 0.0.0.0/0)"
  }
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
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

variable "aws_profile" {
  description = "AWS CLI profile for local authentication. Leave empty in CI (OIDC sets credentials via environment variables)."
  type        = string
  default     = ""
}
