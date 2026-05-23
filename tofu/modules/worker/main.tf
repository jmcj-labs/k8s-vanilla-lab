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

# Security Group for Workers
resource "aws_security_group" "worker" {
  name                   = "${var.name}-worker-sg"
  description            = "Security group for Kubernetes worker nodes"
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true

  # SSH access from my IP only
  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  # Kubelet API - from control plane
  ingress {
    description     = "Kubelet API from control plane"
    from_port       = 10250
    to_port         = 10250
    protocol        = "tcp"
    security_groups = [var.control_plane_security_group_id]
  }

  # NodePort Services (30000-32767)
  ingress {
    description = "NodePort Services"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  # Allow all traffic between workers (pod-to-pod communication)
  ingress {
    description = "Worker to worker communication"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Allow traffic from control plane SG
  ingress {
    description     = "All from control plane"
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [var.control_plane_security_group_id]
  }

  # Egress - allow all
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-worker-sg"
      Role = "worker"
    }
  )
}

# Cleanup orphaned ENIs (created by Kubernetes/Flannel, not tracked by OpenTofu)
# before destroying the security group. On destroy this runs first, then the SG.
resource "terraform_data" "cleanup_worker_enis" {
  depends_on = [aws_security_group.worker]

  input = {
    sg_id  = aws_security_group.worker.id
    region = data.aws_region.current.name
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

# Security group rule to allow workers to reach control plane
resource "aws_security_group_rule" "cp_from_workers" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = var.control_plane_security_group_id
  source_security_group_id = aws_security_group.worker.id
  description              = "Allow all from worker nodes"
}

# IAM Role for Workers
resource "aws_iam_role" "worker" {
  name = "${var.name}-worker-role"

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
      Name = "${var.name}-worker-role"
      Role = "worker"
    }
  )
}

# IAM Policy for SSM Parameter Store (read-only for join token)
resource "aws_iam_role_policy" "worker_ssm" {
  name = "${var.name}-worker-ssm-policy"
  role = aws_iam_role.worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/k8s/${var.cluster_name}/*"
      }
    ]
  })
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "worker" {
  name = "${var.name}-worker-profile"
  role = aws_iam_role.worker.name

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-worker-profile"
      Role = "worker"
    }
  )
}

# Worker Instances
resource "aws_instance" "worker" {
  count = var.worker_count

  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.worker.id]
  iam_instance_profile   = aws_iam_instance_profile.worker.name
  user_data              = var.user_data

  # Spot or On-Demand configuration
  instance_market_options {
    market_type = var.capacity_type == "spot" ? "spot" : null

    dynamic "spot_options" {
      for_each = var.capacity_type == "spot" ? [1] : []
      content {
        # Note: 'stop' interruption behavior works for manual stops.
        # AWS spot reclamations always terminate regardless of this setting.
        # Acceptable for lab use. Use on-demand for critical workloads.
        spot_instance_type             = "persistent"
        instance_interruption_behavior = "stop"
      }
    }
  }

  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size
    delete_on_termination = true
    encrypted             = true

    tags = merge(
      var.tags,
      {
        Name = "${var.name}-worker-${count.index + 1}-root"
        Role = "worker"
      }
    )
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = merge(
    var.tags,
    {
      Name                                        = "${var.name}-worker-${count.index + 1}"
      Role                                        = "worker"
      WorkerIndex                                 = count.index + 1
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  )

  lifecycle {
    ignore_changes = [
      user_data,
      ami
    ]
  }
}
