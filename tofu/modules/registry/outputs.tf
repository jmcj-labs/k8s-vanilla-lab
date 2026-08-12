output "repository_urls" {
  description = "Map of repository name → URL (Repo 2 tags images by commit SHA)"
  value       = { for name, repo in aws_ecr_repository.app : name => repo.repository_url }
}

output "repository_arns" {
  description = "ARNs of the four app repositories (consumed by the worker pull policy)"
  value       = [for repo in aws_ecr_repository.app : repo.arn]
}

output "app_ci_role_arn" {
  description = "ARN of the logistics-lab CI role (set as AWS_ROLE_ARN in Repo 2)"
  value       = aws_iam_role.app_ci.arn
}
