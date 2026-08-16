output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

# Node shells are SSM sessions now, not ssh — there is no inbound SSH and no
# key (INCIDENTS #16). Use `make ssm-cp CP_INDEX=n` / `make ssm-worker`.
output "control_plane_public_ips" {
  description = "Control plane public IPs by index (auto-assigned — SSH/egress only; the API endpoint is the NLB, ADR-007)"
  value       = module.control_plane.public_ips
}

output "control_plane_private_ips" {
  description = "Control plane private IPs by index"
  value       = module.control_plane.private_ips
}

output "worker_public_ips" {
  description = "Worker node public IPs"
  value       = module.worker.public_ips
}

output "worker_private_ips" {
  description = "Worker node private IPs"
  value       = module.worker.private_ips
}

output "cluster_info" {
  description = "Cluster summary"
  value = {
    cluster_name        = var.cluster_name
    region              = var.aws_region
    environment         = var.environment
    control_plane_count = var.control_plane_count
    worker_count        = var.worker_count
    capacity_type       = var.worker_capacity_type
    kubernetes_api      = "https://${module.nlb.dns_name}:6443"
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

output "ecr_repository_urls" {
  description = "ECR repository URLs for logistics-lab images (tagged by commit SHA)"
  value       = module.registry.repository_urls
}

output "logistics_lab_ci_role_arn" {
  description = "OIDC CI role for jmcj-labs/logistics-lab (set as AWS_ROLE_ARN in Repo 2)"
  value       = module.registry.app_ci_role_arn
}

output "backup_bucket_name" {
  description = "Backups bucket this cluster writes to (persistent stack — survives destroy)"
  value       = local.backup_bucket_name
}

output "gateway_nodeport" {
  description = "Deterministic Gateway NodePort (source of truth for install.sh and the smoke)"
  value       = var.gateway_nodeport
}

output "nlb_dns_name" {
  description = "Public DNS of the application NLB — fresh every apply; never persist a previous value"
  value       = module.nlb.dns_name
}
