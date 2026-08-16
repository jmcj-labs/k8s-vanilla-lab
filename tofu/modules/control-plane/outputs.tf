output "instance_ids" {
  description = "Control plane instance IDs, by index (0 = kubeadm init node)"
  value       = aws_instance.control_plane[*].id
}

output "public_ips" {
  description = "Control plane public IPs (auto-assigned, SSH/egress only — the API endpoint is the NLB's DNS, ADR-007)"
  value       = aws_instance.control_plane[*].public_ip
}

output "private_ips" {
  description = "Control plane private IPs, by index"
  value       = aws_instance.control_plane[*].private_ip
}

output "security_group_id" {
  description = "Control plane security group ID"
  value       = aws_security_group.control_plane.id
}

output "iam_role_arn" {
  description = "Control plane IAM role ARN"
  value       = aws_iam_role.control_plane.arn
}
