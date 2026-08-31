output "backup_bucket_name" {
  description = "Backups bucket name. The cluster stack consumes it by VARIABLE (backup_bucket_name), not remote state — the graphs stay decoupled; both sides derive the same default."
  value       = aws_s3_bucket.backups.id
}

output "backup_bucket_arn" {
  description = "Backups bucket ARN"
  value       = aws_s3_bucket.backups.arn
}

output "cnpg_backup_user_arn" {
  description = "IAM user whose access keys (created manually, deposited in SSM) barman uses for cnpg/*"
  value       = aws_iam_user.cnpg_backup.arn
}

output "node_readiness_repository_url" {
  description = "ECR repository for the per-node readiness aggregator (INCIDENTS #20). Survives cluster destroy because the DaemonSet pins its image by digest."
  value       = aws_ecr_repository.node_readiness.repository_url
}

output "node_readiness_repository_arn" {
  description = "ARN of the node-readiness repository — the scope of the CI role's push grant"
  value       = aws_ecr_repository.node_readiness.arn
}
