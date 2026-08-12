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

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
