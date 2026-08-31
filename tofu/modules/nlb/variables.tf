variable "name" {
  description = "Cluster name — prefixes every NLB-side resource"
  type        = string
}

variable "vpc_id" {
  description = "VPC hosting the workers"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR — scope of the NLB SG's egress towards the workers' NodePort"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet for the internet-facing NLB (single AZ today — zonal resilience is declared post-S2 debt)"
  type        = string
}

variable "gateway_nodeport" {
  description = "Deterministic NodePort of the Gateway Service (single source of truth in the lab env)"
  type        = number
}

variable "worker_count" {
  description = "STATIC worker count — drives the target attachments' count (never for_each over unknown IDs, INCIDENTS #11)"
  type        = number
}

variable "worker_instance_ids" {
  description = "Worker EC2 instance IDs to register as targets (values may be unknown at plan; only count may not)"
  type        = list(string)
}

variable "control_plane_count" {
  description = "STATIC control-plane count — drives the API target attachments' count (INCIDENTS #11 discipline)"
  type        = number
}

variable "control_plane_instance_ids" {
  description = "Control-plane EC2 instance IDs to register as API targets (values may be unknown at plan; only count may not)"
  type        = list(string)
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}

variable "readiness_port" {
  description = "Port of the per-node readiness aggregator the gateway target group health-checks (Pieza 0 / INCIDENTS #20)"
  type        = number
  default     = 9890
}
