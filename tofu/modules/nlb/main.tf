# Internet-facing NLB in front of the shared Gateway — S2 piece 2.
#
# Decisions ratified in brief #S2-2 (all closed, do not re-litigate):
# - TLS PASSTHROUGH: pure L4. TCP/443 listener → TCP target group → the
#   Gateway keeps terminating TLS with its cert-manager cert and SNI
#   routing. An NLB TLS listener would not "break gRPC" (ALPN exists) —
#   it would break the passthrough design; TCP is the decision.
# - INSTANCE targets on the deterministic NodePort (30443). IP targets are
#   discarded by design: the LB-IPAM VIP is not announced, pods are not
#   reachable in tunnel mode, and IP coupling is churn.
# - NATIVE client-IP preservation; Proxy Protocol v2 is PROHIBITED (in
#   Cilium it is global per Gateway and would break in-cluster VIP access
#   and the health checks).
# - Cross-zone OFF explicitly: one AZ today; the NLB adds no zonal
#   resilience — that is piece 3's problem, and pretending otherwise in
#   config would be a lie.
# - Health check is TCP on the traffic port: HTTPS without SNI would give
#   false negatives; TCP proves the datapath, the e2e proves semantics.
#   Design note ON RECORD: NLB fails OPEN when every target is unhealthy —
#   security rests on the security groups, never on health state.
# - The NLB lives and dies with the cluster (FinOps): fresh DNS every
#   apply, published as an output — never persist yesterday's name.

# SG attached AT CREATION (AWS does not allow adding the FIRST SG to an
# NLB after the fact). No inline rules — INCIDENTS #6.
resource "aws_security_group" "nlb" {
  name        = "${var.name}-nlb-sg"
  description = "Internet ingress for the application NLB (TCP/443 only)"
  vpc_id      = var.vpc_id

  revoke_rules_on_delete = true

  tags = merge(var.tags, {
    Name = "${var.name}-nlb-sg"
    Role = "nlb"
  })
}

resource "aws_vpc_security_group_ingress_rule" "https_world" {
  security_group_id = aws_security_group.nlb.id
  description       = "Application entry: HTTPS from anywhere (TLS terminates at the Gateway)"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "to_nodeport" {
  security_group_id = aws_security_group.nlb.id
  description       = "Forwarded traffic + TCP health checks to the workers' Gateway NodePort"
  from_port         = var.gateway_nodeport
  to_port           = var.gateway_nodeport
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_lb" "gateway" {
  name               = "${var.name}-gw-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [var.subnet_id]
  security_groups    = [aws_security_group.nlb.id]

  # One AZ, one subnet: cross-zone is meaningless today and OFF on purpose
  # so the (non-)decision is visible. Zonal resilience is piece 3.
  enable_cross_zone_load_balancing = false

  tags = merge(var.tags, {
    Name = "${var.name}-gw-nlb"
    Role = "nlb"
  })
}

resource "aws_lb_target_group" "gateway" {
  name        = "${var.name}-gw-tg"
  port        = var.gateway_nodeport
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  # Explicit even where AWS defaults agree — these are DECISIONS:
  preserve_client_ip = true
  proxy_protocol_v2  = false
  # Ephemeral lab: the default 300s deregistration delay only slows destroy.
  deregistration_delay = 10

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }

  tags = merge(var.tags, {
    Name = "${var.name}-gw-tg"
    Role = "nlb"
  })
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.gateway.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }

  tags = merge(var.tags, {
    Name = "${var.name}-gw-nlb-443"
  })
}

# count on the STATIC worker_count — never for_each over instance IDs,
# which are unknown-after-apply on a fresh plan (INCIDENTS #11 family).
resource "aws_lb_target_group_attachment" "workers" {
  count = var.worker_count

  target_group_arn = aws_lb_target_group.gateway.arn
  target_id        = var.worker_instance_ids[count.index]
  port             = var.gateway_nodeport
}

# The worker-SG side of the pairing (30443 from THIS SG only) lives as an
# inline rule in the worker module: that SG is inline-managed and mixing
# inline with standalone rules deletes rules on apply (INCIDENTS #6).
