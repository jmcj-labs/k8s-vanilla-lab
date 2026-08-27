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
data "aws_caller_identity" "current" {}

locals {
  # common_tags removed - using provider default_tags to avoid case-insensitive duplicates in IAM
  common_tags = {}

  # Same derivation as tofu/envs/persistent — both sides agree on the name
  # without remote-state coupling. Known at plan (caller_identity is a
  # dependency-free data source), and only ever used inside Resource strings.
  backup_bucket_name = var.backup_bucket_name != "" ? var.backup_bucket_name : "${var.cluster_name}-backups-${data.aws_caller_identity.current.account_id}"

  # Kubernetes network configuration
  # (K8s version is not pinned here: bootstrap installs the latest 1.35.x
  # and kubeadm uses its own binary version for the cluster)
  pod_cidr     = "10.244.0.0/16"
  service_cidr = "10.96.0.0/12"

  # SSM parameter paths
  ssm_parameter_base = "/k8s/${var.cluster_name}"

  # cloud-init's MIME decoder corrupts non-ASCII text in 7bit shell parts.
  # Keep both the source fragments and the exact templatefile output ASCII.
  bootstrap_common     = file("${path.module}/../../../bootstrap/common.yaml")
  joined_count_library = file("${path.module}/../../../bootstrap/joined-count.sh")
  kpr_gate_library     = file("${path.module}/../../../bootstrap/kpr-gate.sh")
  fetch_exec_library   = file("${path.module}/../../../bootstrap/fetch-exec.sh")
  bootstrap_prefix     = "bootstrap/${var.cluster_name}"
  bootstrap_cp_founder = templatefile("${path.module}/../../../bootstrap/control-plane.yaml", {
    cluster_name         = var.cluster_name
    aws_region           = var.aws_region
    pod_cidr             = local.pod_cidr
    service_cidr         = local.service_cidr
    api_endpoint_dns     = module.nlb.dns_name
    api_target_group_arn = module.nlb.api_target_group_arn
    ssm_parameter_path   = local.ssm_parameter_base
    kpr_gate_library     = local.kpr_gate_library
  })
  bootstrap_cp_join = [for index in range(var.control_plane_count) : templatefile("${path.module}/../../../bootstrap/control-plane-join.yaml", {
    cluster_name         = var.cluster_name
    aws_region           = var.aws_region
    api_endpoint_dns     = module.nlb.dns_name
    ssm_parameter_path   = local.ssm_parameter_base
    cp_index             = index
    cp_count             = var.control_plane_count
    joined_count_library = local.joined_count_library
  })]
  # INCIDENTS #25: the founder render had reached 16289 of the 16384 bytes EC2
  # allows in user_data, and 60 added lines broke RunInstances on index 0.
  # The renders now travel through S3 and user_data carries only a stub that
  # fetches, verifies the SHA-256 and executes. Changing the transport instead
  # of shaving bytes: shaving buys one apply and leaves the ceiling in place.
  stub_cp_founder = templatefile("${path.module}/../../../bootstrap/stub.yaml", {
    log_file           = "/var/log/k8s-cp-bootstrap.log"
    aws_region         = var.aws_region
    s3_uri             = "s3://${local.backup_bucket_name}/${local.bootstrap_prefix}/02-control-plane-init.sh"
    sha256             = sha256(local.bootstrap_cp_founder)
    dest               = "/opt/k8s-bootstrap/02-control-plane-init.sh"
    fetch_exec_library = local.fetch_exec_library
  })
  stub_cp_join = [for index in range(var.control_plane_count) : templatefile("${path.module}/../../../bootstrap/stub.yaml", {
    log_file           = "/var/log/k8s-cp-bootstrap.log"
    aws_region         = var.aws_region
    s3_uri             = "s3://${local.backup_bucket_name}/${local.bootstrap_prefix}/03-control-plane-join-${index}.sh"
    sha256             = sha256(local.bootstrap_cp_join[index])
    dest               = "/opt/k8s-bootstrap/03-control-plane-join.sh"
    fetch_exec_library = local.fetch_exec_library
  })]
  # The worker payload is 4901 B gzipped -- nowhere near the ceiling, so it
  # stays inline. Migrating what is not under pressure only adds surface.
  bootstrap_worker = templatefile("${path.module}/../../../bootstrap/worker.yaml", {
    cluster_name          = var.cluster_name
    aws_region            = var.aws_region
    ssm_join_token_path   = "${local.ssm_parameter_base}/join-command"
    ssm_ca_cert_hash_path = "${local.ssm_parameter_base}/ca-cert-hash"
  })
}

# INCIDENTS #25: the bootstrap renders travel through S3 instead of riding in
# user_data. The bucket belongs to tofu/envs/persistent and survives, but
# THESE OBJECTS are owned by this stack, so `tofu destroy` removes them and
# leaves no stale founder behind for the next incarnation to fetch.
resource "aws_s3_object" "bootstrap_cp_founder" {
  bucket                 = local.backup_bucket_name
  key                    = "${local.bootstrap_prefix}/02-control-plane-init.sh"
  content                = local.bootstrap_cp_founder
  content_type           = "text/x-shellscript"
  server_side_encryption = "AES256"
  # etag tracks the content, so a re-rendered script replaces the object.
  etag = md5(local.bootstrap_cp_founder)
}

resource "aws_s3_object" "bootstrap_cp_join" {
  # STATIC count (INCIDENTS #11): never a value known only after apply.
  count = var.control_plane_count

  bucket                 = local.backup_bucket_name
  key                    = "${local.bootstrap_prefix}/03-control-plane-join-${count.index}.sh"
  content                = local.bootstrap_cp_join[count.index]
  content_type           = "text/x-shellscript"
  server_side_encryption = "AES256"
  etag                   = md5(local.bootstrap_cp_join[count.index])
}

# Multi-part cloud-init for control planes.
# NLB-FIRST pattern (replaces the historical EIP-first): the stable API
# endpoint rendered into user_data is the NLB's DNS, which depends on no
# instance — so it exists before any node boots.
#
# Index 0 carries TWO scripts (founder + join), every other index only the
# join script. Which one acts is decided AT RUNTIME, not at plan time:
# a rebuilt index 0 finds cp/joined-count in SSM, skips the founder path
# and joins like any replacement (Codex cruce 3 — the static
# `count.index == 0 ? init : join` selector would have re-initialised a
# second cluster on top of the live one).
data "cloudinit_config" "control_plane" {
  count = var.control_plane_count

  gzip          = true
  base64_encode = true

  lifecycle {
    precondition {
      condition = alltrue([
        length(regexall("[^\\x00-\\x7F]", local.bootstrap_common)) == 0,
        length(regexall("[^\\x00-\\x7F]", local.joined_count_library)) == 0,
        length(regexall("[^\\x00-\\x7F]", local.kpr_gate_library)) == 0,
        length(regexall("[^\\x00-\\x7F]", local.fetch_exec_library)) == 0,
        length(regexall("[^\\x00-\\x7F]", local.bootstrap_cp_join[count.index])) == 0,
        length(regexall("[^\\x00-\\x7F]", local.stub_cp_join[count.index])) == 0,
        count.index != 0 || length(regexall("[^\\x00-\\x7F]", local.bootstrap_cp_founder)) == 0,
        count.index != 0 || length(regexall("[^\\x00-\\x7F]", local.stub_cp_founder)) == 0,
      ])
      error_message = "bootstrap source/render contains non-ASCII bytes; cloud-init would corrupt or reject this MIME part"
    }
  }

  part {
    content_type = "text/x-shellscript"
    content      = local.bootstrap_common
    filename     = "01-common.sh"
  }

  # Index 0 only: the founder script. It self-detects genesis vs
  # replacement (SSM cp/joined-count) and exits early when a cluster
  # already exists, leaving the join part below to do the work — that is
  # what makes a REBUILT index 0 join instead of initialising a second
  # cluster (Codex cruce 3).
  dynamic "part" {
    for_each = count.index == 0 ? [1] : []
    content {
      content_type = "text/x-shellscript"
      content      = local.stub_cp_founder
      filename     = "02-control-plane-init.sh"
    }
  }

  # EVERY index, including 0: the join script. It is a no-op on a node that
  # is already a control plane (kube-apiserver manifest present), so on
  # genesis it costs one check and exits.
  part {
    content_type = "text/x-shellscript"
    content      = local.stub_cp_join[count.index]
    filename     = "03-control-plane-join.sh"
  }
}

# Multi-part cloud-init for workers (common + worker scripts)
data "cloudinit_config" "worker" {
  gzip          = true
  base64_encode = true

  lifecycle {
    precondition {
      condition = alltrue([
        length(regexall("[^\\x00-\\x7F]", local.bootstrap_common)) == 0,
        length(regexall("[^\\x00-\\x7F]", local.bootstrap_worker)) == 0,
      ])
      error_message = "bootstrap source/render contains non-ASCII bytes; cloud-init would corrupt or reject this MIME part"
    }
  }

  part {
    content_type = "text/x-shellscript"
    content      = local.bootstrap_common
    filename     = "01-common.sh"
  }

  part {
    content_type = "text/x-shellscript"
    content      = local.bootstrap_worker
    filename     = "02-worker.sh"
  }
}

# Control Plane Module
module "control_plane" {
  source = "../../modules/control-plane"

  name                  = var.cluster_name
  vpc_id                = aws_vpc.main.id
  subnet_id             = aws_subnet.public.id
  instance_type         = var.control_plane_instance_type
  ami_id                = data.aws_ami.ubuntu.id
  key_name              = var.ssh_key_name
  control_plane_count   = var.control_plane_count
  user_data_base64      = data.cloudinit_config.control_plane[*].rendered
  bootstrap_bucket_name = local.backup_bucket_name
  bootstrap_prefix      = local.bootstrap_prefix
  nlb_security_group_id = module.nlb.security_group_id
  cluster_name          = var.cluster_name
  backup_bucket_name    = local.backup_bucket_name
  tags                  = local.common_tags

  # IGW must exist before instances (internet access needed during bootstrap).
  # On destroy this reverses: module destroyed before IGW, releasing EIP
  # associations so the IGW can detach from the VPC cleanly. The EBS cleanup
  # dependency makes "ALL instances dead before deleting volumes" strict —
  # workers alone would leave the CP racing the cleanup.
  # aws_s3_object.*: the stub in user_data fetches them at first boot, and
  # nothing in the arguments references them, so the edge must be explicit or
  # an instance could come up before its script exists (INCIDENTS #25).
  depends_on = [
    aws_internet_gateway.main,
    terraform_data.cleanup_dynamic_ebs,
    aws_s3_object.bootstrap_cp_founder,
    aws_s3_object.bootstrap_cp_join,
  ]
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

  developer_role_arn      = module.access.developer_role_arn
  attach_assume_developer = true
  tags                    = local.common_tags
}

# Worker Module
# Destroy-time cleanup of the DYNAMIC EBS volumes the CSI driver provisions
# at runtime (PG/Kafka PVCs) — OpenTofu never tracks them, so without this
# they linger `available` and billing after every destroy (CLUSTER.md §5).
# Safe to delete blindly since S2 piece 1: the conservation path is S3
# (CNPG base+WAL and etcd snapshots in the persistent bucket), not these
# volumes.
#
# Ordering trick (inverse of the orphaned-ENI pattern): BOTH instance
# modules depend ON this resource, so on destroy every instance dies FIRST,
# the CSI volumes detach, and only then does this provisioner run — with a
# bounded wait for volumes still detaching. Scoped by the CSI tags AND the
# cluster's OWN tag (k8s-cluster, stamped by the gp3 StorageClass
# tagSpecification), the same tag the CI role's DeleteVolume permission is
# conditioned on. Fails the destroy HARD if volumes remain after the last
# retry, and only tolerates the transient detaching errors — anything else
# aborts immediately.
resource "terraform_data" "cleanup_dynamic_ebs" {
  input = {
    region  = var.aws_region
    cluster = var.cluster_name
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -eu
      echo "Cleaning dynamic CSI EBS volumes (backups in S3 are the conservation path)..."
      REMAINING=-1
      for ATTEMPT in $(seq 1 12); do
        VOLS=$(aws ec2 describe-volumes \
          --filters "Name=status,Values=available" \
                    "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
                    "Name=tag:ebs.csi.aws.com/cluster,Values=true" \
                    "Name=tag:k8s-cluster,Values=${self.input.cluster}" \
          --query 'Volumes[*].VolumeId' \
          --output text \
          --region ${self.input.region})
        for VOL in $VOLS; do
          [ -z "$VOL" ] && continue
          echo "Deleting volume $VOL"
          if ! OUT=$(aws ec2 delete-volume --volume-id "$VOL" --region ${self.input.region} 2>&1); then
            case "$OUT" in
              *VolumeInUse*|*IncorrectState*)
                echo "  transient: $VOL still detaching" ;;
              *)
                echo "$OUT" >&2
                exit 1 ;;
            esac
          fi
        done
        REMAINING=$(aws ec2 describe-volumes \
          --filters "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
                    "Name=tag:ebs.csi.aws.com/cluster,Values=true" \
                    "Name=tag:k8s-cluster,Values=${self.input.cluster}" \
          --query 'length(Volumes)' --output text \
          --region ${self.input.region})
        [ "$REMAINING" = "0" ] && break
        echo "  $REMAINING volume(s) still present — retry $ATTEMPT/12"
        sleep 10
      done
      if [ "$REMAINING" != "0" ]; then
        echo "ERROR: $REMAINING dynamic CSI volume(s) still present after all retries — failing the destroy" >&2
        exit 1
      fi
      echo "Dynamic EBS cleanup complete."
    EOT
  }
}

module "worker" {
  source = "../../modules/worker"

  name                            = var.cluster_name
  vpc_id                          = aws_vpc.main.id
  subnet_id                       = aws_subnet.public.id
  instance_type                   = var.worker_instance_type
  ami_id                          = data.aws_ami.ubuntu.id
  key_name                        = var.ssh_key_name
  control_plane_security_group_id = module.control_plane.security_group_id
  user_data_base64                = data.cloudinit_config.worker.rendered
  ecr_repository_arns             = module.registry.repository_arns
  cluster_name                    = var.cluster_name
  worker_count                    = var.worker_count
  capacity_type                   = var.worker_capacity_type
  gateway_nodeport                = var.gateway_nodeport
  nlb_security_group_id           = module.nlb.security_group_id
  tags                            = local.common_tags

  depends_on = [module.control_plane, aws_internet_gateway.main, terraform_data.cleanup_dynamic_ebs]
}

# NLB (S2 pieces 2+3) — application entry AND API endpoint; lives and dies
# with the cluster. The module-level mutual references are fine: the
# RESOURCE graph is acyclic (the NLB itself and its SG depend on no
# instance; CP/worker SG rules and user_data reference the NLB side; the
# target attachments reference the instance IDs last).
module "nlb" {
  source = "../../modules/nlb"

  name                       = var.cluster_name
  vpc_id                     = aws_vpc.main.id
  vpc_cidr                   = var.vpc_cidr
  subnet_id                  = aws_subnet.public.id
  gateway_nodeport           = var.gateway_nodeport
  worker_count               = var.worker_count
  worker_instance_ids        = module.worker.instance_ids
  control_plane_count        = var.control_plane_count
  control_plane_instance_ids = module.control_plane.instance_ids
  tags                       = local.common_tags
}
