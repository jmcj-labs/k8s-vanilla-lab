variable "management_account_id" {
  description = "AWS account ID of the organization management account (where IAM Identity Center lives). Supply via terraform.tfvars (never versioned)."
  type        = string
}

variable "lab_account_id" {
  description = "AWS account ID of the lab member account (cluster + stable IAM roles). Account assignments are provisioned THERE. Supply via terraform.tfvars (never versioned)."
  type        = string
}

variable "platform_user_name" {
  description = "Username of the EXISTING Identity Center human user to enrol in platform-admins. The user itself is never managed by this stack."
  type        = string
}

variable "aws_profile" {
  description = "Local AWS profile with management-account credentials. This stack is only ever applied locally."
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "Cluster name — used to build the stable role names the permission sets may assume"
  type        = string
  default     = "k8s-vanilla-lab"
}

variable "dev_user_name" {
  description = "Username for the new developer identity"
  type        = string
  default     = "jm-dev"
}

variable "dev_given_name" {
  description = "Given name for jm-dev (personal data — supply via terraform.tfvars)"
  type        = string
}

variable "dev_family_name" {
  description = "Family name for jm-dev (personal data — supply via terraform.tfvars)"
  type        = string
}

variable "dev_email" {
  description = "Email for jm-dev (personal data — supply via terraform.tfvars). No activation mail is sent: initial password is handled manually once (see README)."
  type        = string
}
