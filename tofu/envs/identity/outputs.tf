output "platform_permission_set_arn" {
  description = "ARN of the K8sPlatformBridge permission set"
  value       = aws_ssoadmin_permission_set.platform_bridge.arn
}

output "dev_permission_set_arn" {
  description = "ARN of the K8sDevBridge permission set"
  value       = aws_ssoadmin_permission_set.dev_bridge.arn
}

output "jm_dev_user_id" {
  description = "Identity Store user id of jm-dev (onboarding: set the initial password manually — no activation mail is sent)"
  value       = aws_identitystore_user.jm_dev.user_id
}
