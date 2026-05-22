output "instance_ids" {
  description = "Worker instance IDs"
  value       = aws_instance.worker[*].id
}

output "public_ips" {
  description = "Worker public IPs (may change on stop/start for spot instances)"
  value       = aws_instance.worker[*].public_ip
}

output "private_ips" {
  description = "Worker private IPs"
  value       = aws_instance.worker[*].private_ip
}

output "security_group_id" {
  description = "Worker security group ID"
  value       = aws_security_group.worker.id
}

output "iam_role_arn" {
  description = "Worker IAM role ARN"
  value       = aws_iam_role.worker.arn
}

output "capacity_type" {
  description = "Capacity type used (spot or on-demand)"
  value       = var.capacity_type
}

output "worker_count" {
  description = "Number of worker nodes deployed"
  value       = var.worker_count
}
