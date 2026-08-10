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
resource "aws_security_group" "control_plane" {
  name                   = "${var.name}-cp-sg"
  description            = "Security group for Kubernetes control plane"
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

  # Kubernetes API server - restricted by default to my_ip, expandable via variable
  ingress {
    description = "Kubernetes API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = length(var.api_server_allowed_cidrs) > 0 ? var.api_server_allowed_cidrs : [var.my_ip]
  }

  # etcd server client API (control plane to control plane)
  ingress {
    description = "etcd server client API"
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    self        = true
  }

  # Kubelet API
  ingress {
    description = "Kubelet API"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    self        = true
  }

  # kube-scheduler
  ingress {
    description = "kube-scheduler"
    from_port   = 10259
    to_port     = 10259
    protocol    = "tcp"
    self        = true
  }

  # kube-controller-manager
  ingress {
    description = "kube-controller-manager"
    from_port   = 10257
    to_port     = 10257
    protocol    = "tcp"
    self        = true
  }

  # Allow all traffic from workers (self = placeholder; actual rule added via aws_security_group_rule in worker module)
  ingress {
    description = "All from workers"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
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
      Name = "${var.name}-cp-sg"
      Role = "control-plane"
    }
  )
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
  user_data              = var.user_data

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
    # extra routing hop on the return path (verified 2026-08-10: with 2,
    # IMDS times out from the pod network).
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
    ignore_changes = [
      user_data,
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
