output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "control_plane_public_ip" {
  description = "Control plane public IP (Elastic IP)"
  value       = module.control_plane.public_ip
}

output "control_plane_private_ip" {
  description = "Control plane private IP"
  value       = module.control_plane.private_ip
}

output "worker_public_ips" {
  description = "Worker node public IPs"
  value       = module.worker.public_ips
}

output "worker_private_ips" {
  description = "Worker node private IPs"
  value       = module.worker.private_ips
}

output "kubeconfig_command" {
  description = "Command to extract kubeconfig from control plane"
  value       = module.control_plane.kubeconfig_command
}

output "ssh_control_plane" {
  description = "SSH command for control plane"
  value       = "ssh -i ~/.ssh/YOUR_KEY.pem ubuntu@${module.control_plane.public_ip}"
}

output "ssh_workers" {
  description = "SSH commands for workers"
  value = [
    for ip in module.worker.public_ips :
    "ssh -i ~/.ssh/YOUR_KEY.pem ubuntu@${ip}"
  ]
}

output "cluster_info" {
  description = "Cluster summary"
  value = {
    cluster_name   = var.cluster_name
    region         = var.aws_region
    environment    = var.environment
    worker_count   = var.worker_count
    capacity_type  = var.worker_capacity_type
    kubernetes_api = "https://${module.control_plane.public_ip}:6443"
  }
}

output "platform_admin_role_arn" {
  description = "Stable IAM role for cluster-admin access (aws-iam-authenticator)"
  value       = module.access.platform_admin_role_arn
}

output "developer_role_arn" {
  description = "Stable IAM role for namespace-scoped developer access (aws-iam-authenticator)"
  value       = module.access.developer_role_arn
}
