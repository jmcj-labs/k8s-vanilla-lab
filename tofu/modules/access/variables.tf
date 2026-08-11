variable "cluster_name" {
  description = "Cluster name — prefixes the stable role names (must stay within the k8s-vanilla-lab-* prefix the CI role can administer)"
  type        = string
}

variable "github_actions_role_name" {
  description = "Name of the GitHub OIDC role in this account, trusted on the stable roles exclusively for the CI RBAC smoke test"
  type        = string
  default     = "k8s-vanilla-lab-github-actions"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
