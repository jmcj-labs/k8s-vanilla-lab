variable "repositories" {
  description = "ECR repository names for the logistics-lab services (Repo 2 pushes, workers pull)"
  type        = list(string)
  default     = ["shipments-api", "routing", "tracking-events", "traffic-generator"]
}

variable "app_repo" {
  description = "GitHub org/repo of the application repository whose CI may push (sub claim of the OIDC trust)"
  type        = string
  default     = "jmcj-labs/logistics-lab"
}

variable "ci_role_name" {
  description = "Name of the app repo's dedicated OIDC CI role (managed here, exact-scoped in bootstrap-aws.sh)"
  type        = string
  default     = "logistics-lab-ci"
}

variable "developer_role_arn" {
  description = "ARN of the k8s-vanilla-lab-developer role the app CI may assume (its only non-ECR action). Used as the policy Resource; may be unknown at plan."
  type        = string
  default     = ""
}

variable "attach_assume_developer" {
  description = "Whether to attach the assume-developer policy to the app CI role. Static bool (known at plan) so count never depends on an unknown ARN — INCIDENTS #11."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
