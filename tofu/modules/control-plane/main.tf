terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_region" "current" {}

# Security Group for Control Plane
#
# NO inline ingress/egress blocks here: the worker module attaches its own
# rule (worker -> CP) to this SG, and OpenTofu treats inline rules as the
# complete rule set — any apply would delete the externally added rule
# (observed 2026-08-10: the worker->CP rule was wiped by a partial apply).
# All rules live as standalone aws_vpc_security_group_*_rule resources.
resource "aws_security_group" "control_plane" {
  name                   = "${var.name}-cp-sg"
  description            = "Security group for Kubernetes control plane"
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-cp-sg"
      Role = "control-plane"
    }
  )
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.control_plane.id
  description       = "SSH from my IP"
  cidr_ipv4         = var.my_ip
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

# Kubernetes API server - restricted by default to my_ip, expandable via variable
resource "aws_vpc_security_group_ingress_rule" "api_server" {
  for_each          = toset(length(var.api_server_allowed_cidrs) > 0 ? var.api_server_allowed_cidrs : [var.my_ip])
  security_group_id = aws_security_group.control_plane.id
  description       = "Kubernetes API"
  cidr_ipv4         = each.value
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "etcd" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "etcd server client API (control plane to control plane)"
  referenced_security_group_id = aws_security_group.control_plane.id
  from_port                    = 2379
  to_port                      = 2380
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "kubelet" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "Kubelet API"
  referenced_security_group_id = aws_security_group.control_plane.id
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "kube_scheduler" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "kube-scheduler"
  referenced_security_group_id = aws_security_group.control_plane.id
  from_port                    = 10259
  to_port                      = 10259
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "kube_controller_manager" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "kube-controller-manager"
  referenced_security_group_id = aws_security_group.control_plane.id
  from_port                    = 10257
  to_port                      = 10257
  ip_protocol                  = "tcp"
}

# All traffic between control-plane ENIs (self). The worker -> CP rule is
# owned by the worker module (aws_vpc_security_group_ingress_rule.cp_from_workers).
resource "aws_vpc_security_group_ingress_rule" "all_from_self" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "All traffic from this SG (self)"
  referenced_security_group_id = aws_security_group.control_plane.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.control_plane.id
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Cleanup orphaned ENIs (created by Kubernetes/CNI, not tracked by OpenTofu)
# before destroying the security group. On destroy this runs first, then the SG.
resource "terraform_data" "cleanup_cp_enis" {
  depends_on = [aws_security_group.control_plane]

  input = {
    sg_id  = aws_security_group.control_plane.id
    region = data.aws_region.current.id
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "Cleaning orphaned ENIs for SG ${self.input.sg_id}..."
      ENIS=$(aws ec2 describe-network-interfaces \
        --filters "Name=group-id,Values=${self.input.sg_id}" \
                  "Name=status,Values=available" \
        --query 'NetworkInterfaces[*].NetworkInterfaceId' \
        --output text \
        --region ${self.input.region} 2>/dev/null || echo "")
      for ENI in $ENIS; do
        [ -z "$ENI" ] && continue
        echo "Deleting ENI $ENI"
        aws ec2 delete-network-interface \
          --network-interface-id "$ENI" \
          --region ${self.input.region} || true
      done
      echo "ENI cleanup complete."
    EOT
  }
}

# IAM Role for Control Plane
resource "aws_iam_role" "control_plane" {
  name = "${var.name}-cp-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-cp-role"
      Role = "control-plane"
    }
  )
}

# IAM Policy for SSM Parameter Store (bootstrap token storage)
resource "aws_iam_role_policy" "control_plane_ssm" {
  name = "${var.name}-cp-ssm-policy"
  role = aws_iam_role.control_plane.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter",
          "ssm:DeleteParameter"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/k8s/${var.cluster_name}/*"
      }
    ]
  })
}

# etcd backups (S2 piece 1): the backup CronJob runs hostNetwork on this
# node, so the instance role IS its identity — IMDS works without touching
# the IMDS CCNP or its exception. Write-only to the etcd/ prefix: a
# compromised CP must not be able to read or delete existing snapshots.
resource "aws_iam_role_policy" "control_plane_etcd_backup" {
  count = var.enable_etcd_backup_policy ? 1 : 0

  name = "${var.name}-cp-etcd-backup"
  role = aws_iam_role.control_plane.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EtcdSnapshotPut"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::${var.backup_bucket_name}/etcd/*"
      }
    ]
  })
}

# EBS CSI driver: EC2 volume operations (attach/detach/create/delete)
resource "aws_iam_role_policy_attachment" "control_plane_ebs_csi" {
  role       = aws_iam_role.control_plane.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "control_plane" {
  name = "${var.name}-cp-profile"
  role = aws_iam_role.control_plane.name

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-cp-profile"
      Role = "control-plane"
    }
  )
}

# Elastic IP for Control Plane (created BEFORE instance to avoid circular dependency)
resource "aws_eip" "control_plane" {
  domain = "vpc"

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-cp-eip"
      Role = "control-plane"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

# Control Plane Instance
resource "aws_instance" "control_plane" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.control_plane.id]
  iam_instance_profile   = aws_iam_instance_profile.control_plane.name
  # cloud-init is rendered gzip+base64 (cloudinit_config): the provider
  # contract requires user_data_base64 for pre-encoded data — plain
  # user_data corrupts it and breaks in-place instance updates.
  user_data_base64 = var.user_data_base64

  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size
    delete_on_termination = true
    encrypted             = true

    tags = merge(
      var.tags,
      {
        Name = "${var.name}-cp-root"
        Role = "control-plane"
      }
    )
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # Hop limit 3 so pod-network workloads (EBS CSI driver: credentials +
    # metadata) can reach IMDSv2. 1 only serves the host; 2 covers plain
    # container bridges but NOT Cilium in tunnel routing mode, which adds an
    # extra routing hop on the return path (observed 2026-08-10: with 2,
    # IMDS times out from the pod network; 3 is the working hypothesis).
    http_put_response_hop_limit = 3
  }

  tags = merge(
    var.tags,
    {
      Name                                        = "${var.name}-cp"
      Role                                        = "control-plane"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  )

  lifecycle {
    # user_data kept alongside user_data_base64 to absorb the attribute
    # migration on instances created before the rename (cloud-init is
    # first-boot only, so bootstrap changes never rebuild instances).
    ignore_changes = [
      user_data,
      user_data_base64,
      ami
    ]
  }
}

# EIP Association (after instance creation)
resource "aws_eip_association" "control_plane" {
  instance_id   = aws_instance.control_plane.id
  allocation_id = aws_eip.control_plane.id
}

# Cleanup SSM parameters written by bootstrap (kubeconfig, join data).
# Runs before the IAM role is destroyed so the delete calls succeed.
resource "terraform_data" "cleanup_cp_ssm" {
  depends_on = [aws_iam_role_policy.control_plane_ssm]

  input = {
    cluster_name = var.cluster_name
    region       = data.aws_region.current.id
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "Deleting SSM parameters for cluster ${self.input.cluster_name}..."
      PARAMS=$(aws ssm get-parameters-by-path \
        --path "/k8s/${self.input.cluster_name}" \
        --query 'Parameters[*].Name' \
        --output text \
        --region ${self.input.region} 2>/dev/null || echo "")
      for PARAM in $PARAMS; do
        [ -z "$PARAM" ] && continue
        echo "Deleting SSM parameter $PARAM"
        aws ssm delete-parameter \
          --name "$PARAM" \
          --region ${self.input.region} || true
      done
      echo "SSM cleanup complete."
    EOT
  }
}
