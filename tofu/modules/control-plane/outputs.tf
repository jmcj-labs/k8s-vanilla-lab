output "instance_id" {
  description = "Control plane instance ID"
  value       = aws_instance.control_plane.id
}

output "public_ip" {
  description = "Control plane Elastic IP (static public IP)"
  value       = aws_eip.control_plane.public_ip
}

output "private_ip" {
  description = "Control plane private IP"
  value       = aws_instance.control_plane.private_ip
}

output "security_group_id" {
  description = "Control plane security group ID"
  value       = aws_security_group.control_plane.id
}

output "iam_role_arn" {
  description = "Control plane IAM role ARN"
  value       = aws_iam_role.control_plane.arn
}

output "kubeconfig_command" {
  description = "Command to extract kubeconfig from control plane"
  value       = "ssh -i ~/.ssh/YOUR_KEY.pem ubuntu@${aws_eip.control_plane.public_ip} 'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/config && sed -i 's|server: https://.*:6443|server: https://${aws_eip.control_plane.public_ip}:6443|' ~/.kube/config"
}
