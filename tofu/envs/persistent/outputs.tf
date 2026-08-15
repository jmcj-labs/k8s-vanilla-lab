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
