terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

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
#   resilience — piece 3 delivers NODE HA (3 CPs, one AZ), zonal stays
#   declared post-S2 debt, and pretending otherwise in config would be a lie.
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
  description = "Internet ingress for the cluster NLB (TCP/443 app + TCP/6443 API)"
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
  description       = "Forwarded traffic + TCP health checks to the worker Gateway NodePort"
  from_port         = var.gateway_nodeport
  to_port           = var.gateway_nodeport
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

# AVD-AWS-0053 warns against ACCIDENTAL public exposure. This exposure is
# the deliverable: an internet-facing NLB carrying the application entry
# (TCP/443, brief #S2-2) and the Kubernetes API endpoint (TCP/6443, brief
# #S2-3 — public by design since ADR-004), backed by SG scoping on both
# sides (world→443/6443 here; NodePort only from this SG on the workers,
# 6443 only from this SG on the control planes) with TLS terminating at
# the Gateway and cert/IAM auth at the API. No exp date: a public ingress
# LB is public by definition — not a decision to revisit.
#trivy:ignore:AVD-AWS-0053
resource "aws_lb" "gateway" {
  name               = "${var.name}-gw-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [var.subnet_id]
  security_groups    = [aws_security_group.nlb.id]

  # One AZ, one subnet: cross-zone is meaningless today and OFF on purpose
  # so the (non-)decision is visible. Piece 3 added NODE HA (3 CPs in this
  # same AZ) — zonal resilience remains declared post-S2 debt.
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

  # Pieza 0 / INCIDENTS #20. This used to be TCP on traffic-port, and that was
  # measured to be blind: on 2026-08-31, 22 consecutive samples reported this
  # target group HEALTHY for a worker whose Envoy was stopped, because Cilium's
  # agent programs the NodePort independently of whether Envoy can serve
  # (docs/evidence/h3-2026-08-31/). The check now asks the per-node aggregator,
  # which answers 200 only with the AND of the agent and Envoy.
  #
  # Thresholds are EXPLICIT rather than inherited. The H3 experiment cost a
  # misread window because nobody could say from the code how long a target
  # takes to flip: it was interval 30 x threshold 3, up to ~95s, and that had to
  # be recovered from the AWS defaults. 10 x 2 puts detection under ~30s and,
  # more importantly, puts the number in the file.
  health_check {
    protocol = "HTTP"
    port     = tostring(var.readiness_port)
    path     = "/healthz"
    # The aggregator answers 200 or 503 and nothing else; the default 200-399
    # range would accept codes it never emits.
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(var.tags, {
    Name = "${var.name}-gw-tg"
    Role = "nlb"
  })
}

# The health check leaves the NLB's ENIs towards the aggregator's port, so the
# NLB's own egress has to allow it -- the forwarded-traffic rule only covers
# the NodePort.
resource "aws_vpc_security_group_egress_rule" "to_readiness" {
  security_group_id = aws_security_group.nlb.id
  description       = "HTTP health checks to the per-node readiness aggregator"
  from_port         = var.readiness_port
  to_port           = var.readiness_port
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
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

# ── Kubernetes API endpoint — S2 piece 3 (ADR-007) ──────────────────────────
#
# The SAME NLB fronts the API server on TCP/6443 towards the 3 control
# planes. Coupling application entry and control-plane endpoint in one
# resource is DECLARED AND ACCEPTED in this lab (a bad NLB mutation affects
# both) — see ADR-007 and CLUSTER.md §3/§5.
#
# The API was public by design (ADR-004: TLS + certificate auth, CI runners
# with dynamic IPs); it stays public but now enters through the single door.
# The CPs' own SG no longer accepts 6443 from the world — only from this SG.

resource "aws_vpc_security_group_ingress_rule" "api_world" {
  security_group_id = aws_security_group.nlb.id
  description       = "Kubernetes API: public by design (ADR-004), now through the NLB only"
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "to_api" {
  security_group_id = aws_security_group.nlb.id
  description       = "Forwarded API traffic + TCP health checks to the control planes"
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_lb_target_group" "api" {
  name        = "${var.name}-api-tg"
  port        = 6443
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  # OPPOSITE of the application TG, on purpose: the CPs are CLIENTS of the
  # endpoint that has them as TARGETS (kubeconfigs, Cilium agents, kubelets).
  # Hairpin with client-IP preservation is explicitly discouraged by AWS
  # (a target connecting to itself through the NLB sees its own IP as the
  # source and the connection fails). preserve_client_ip=false makes the
  # source the NLB's private IP and the hairpin safe. PPv2 stays off.
  preserve_client_ip   = false
  proxy_protocol_v2    = false
  deregistration_delay = 10

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }

  tags = merge(var.tags, {
    Name = "${var.name}-api-tg"
    Role = "nlb"
  })
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.gateway.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  tags = merge(var.tags, {
    Name = "${var.name}-gw-nlb-6443"
  })
}

# count on the STATIC control_plane_count — same INCIDENTS #11 discipline
# as the worker attachments above.
resource "aws_lb_target_group_attachment" "control_planes" {
  count = var.control_plane_count

  target_group_arn = aws_lb_target_group.api.arn
  target_id        = var.control_plane_instance_ids[count.index]
  port             = 6443
}
