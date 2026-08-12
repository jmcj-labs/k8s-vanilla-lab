# Data source for Ubuntu 24.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${var.cluster_name}-public-subnet"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# Route Table for Public Subnet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name}-public-rt"
  }
}

# Route Table Association
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Local values for cloud-init templates
locals {
  # common_tags removed - using provider default_tags to avoid case-insensitive duplicates in IAM
  common_tags = {}

  # Kubernetes network configuration
  # (K8s version is not pinned here: bootstrap installs the latest 1.35.x
  # and kubeadm uses its own binary version for the cluster)
  pod_cidr     = "10.244.0.0/16"
  service_cidr = "10.96.0.0/12"

  # SSM parameter paths
  ssm_parameter_base = "/k8s/${var.cluster_name}"

}

# Multi-part cloud-init for control plane (common + control-plane scripts)
data "cloudinit_config" "control_plane" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content      = file("${path.module}/../../../bootstrap/common.yaml")
    filename     = "01-common.sh"
  }

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/../../../bootstrap/control-plane.yaml", {
      cluster_name            = var.cluster_name
      aws_region              = var.aws_region
      pod_cidr                = local.pod_cidr
      service_cidr            = local.service_cidr
      control_plane_public_ip = module.control_plane.public_ip
      ssm_parameter_path      = local.ssm_parameter_base
    })
    filename = "02-control-plane.sh"
  }
}

# Multi-part cloud-init for workers (common + worker scripts)
data "cloudinit_config" "worker" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content      = file("${path.module}/../../../bootstrap/common.yaml")
    filename     = "01-common.sh"
  }

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/../../../bootstrap/worker.yaml", {
      cluster_name          = var.cluster_name
      aws_region            = var.aws_region
      ssm_join_token_path   = "${local.ssm_parameter_base}/join-command"
      ssm_ca_cert_hash_path = "${local.ssm_parameter_base}/ca-cert-hash"
    })
    filename = "02-worker.sh"
  }
}

# Control Plane Module
module "control_plane" {
  source = "../../modules/control-plane"

  name                     = var.cluster_name
  vpc_id                   = aws_vpc.main.id
  subnet_id                = aws_subnet.public.id
  instance_type            = var.control_plane_instance_type
  ami_id                   = data.aws_ami.ubuntu.id
  key_name                 = var.ssh_key_name
  my_ip                    = var.my_ip
  api_server_allowed_cidrs = var.api_server_allowed_cidrs
  user_data_base64         = data.cloudinit_config.control_plane.rendered
  cluster_name             = var.cluster_name
  tags                     = local.common_tags

  # IGW must exist before instances (internet access needed during bootstrap).
  # On destroy this reverses: module destroyed before IGW, releasing EIP
  # associations so the IGW can detach from the VPC cleanly.
  depends_on = [aws_internet_gateway.main]
}

# Stable Kubernetes-access IAM roles (aws-iam-authenticator identities).
# No dependency on the node modules: pure IAM, zero permissions of their own.
module "access" {
  source = "../../modules/access"

  cluster_name = var.cluster_name
  tags         = local.common_tags
}

# Private ECR registry + dedicated CI role for the app repository (Repo 2)
module "registry" {
  source = "../../modules/registry"

  developer_role_arn = module.access.developer_role_arn
  tags               = local.common_tags
}

# Worker Module
module "worker" {
  source = "../../modules/worker"

  name                            = var.cluster_name
  vpc_id                          = aws_vpc.main.id
  subnet_id                       = aws_subnet.public.id
  instance_type                   = var.worker_instance_type
  ami_id                          = data.aws_ami.ubuntu.id
  key_name                        = var.ssh_key_name
  my_ip                           = var.my_ip
  control_plane_security_group_id = module.control_plane.security_group_id
  user_data_base64                = data.cloudinit_config.worker.rendered
  ecr_repository_arns             = module.registry.repository_arns
  cluster_name                    = var.cluster_name
  worker_count                    = var.worker_count
  capacity_type                   = var.worker_capacity_type
  tags                            = local.common_tags

  depends_on = [module.control_plane, aws_internet_gateway.main]
}
