output "dns_name" {
  description = "Public DNS of the NLB — fresh every apply; never persist a previous value"
  value       = aws_lb.gateway.dns_name
}

output "security_group_id" {
  description = "NLB's SG — the ONLY source the workers' Gateway NodePort accepts"
  value       = aws_security_group.nlb.id
}

output "target_group_arn" {
  description = "Application target group ARN (smoke: target set and health assertions)"
  value       = aws_lb_target_group.gateway.arn
}

output "api_target_group_arn" {
  description = "API target group ARN (smoke §14: 3 CP targets healthy)"
  value       = aws_lb_target_group.api.arn
}
