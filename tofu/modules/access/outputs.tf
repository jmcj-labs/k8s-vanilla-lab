output "platform_admin_role_arn" {
  description = "ARN of the stable platform-admin role"
  value       = aws_iam_role.access["platform-admin"].arn
}

output "developer_role_arn" {
  description = "ARN of the stable developer role"
  value       = aws_iam_role.access["developer"].arn
}
