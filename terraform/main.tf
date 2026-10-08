locals {
  common_tags = merge(var.extra_tags, {
    owner   = var.owner
    team    = var.team
    project = var.name
  })

  ssh_cidrs = length(var.ssh_allowed_cidrs) > 0 ? var.ssh_allowed_cidrs : ["${chomp(data.http.my_ip[0].response_body)}/32"]

  bundle_dir   = "${path.module}/../redis-flex-kind"
  bundle_files = fileset(local.bundle_dir, "**")
  bundle_hash  = sha256(join("", [for f in local.bundle_files : filesha256("${local.bundle_dir}/${f}")]))

  license_path    = var.redis_license_file != "" && fileexists(pathexpand(var.redis_license_file)) ? pathexpand(var.redis_license_file) : ""
  license_remote  = "/home/ubuntu/.redis-license.txt"
  installer_env   = merge(var.installer_env, local.license_path == "" ? {} : { REDIS_LICENSE_FILE = local.license_remote })
  installer_env_s = join(" ", [for k, v in local.installer_env : "${k}=${v}"])
}

data "http" "my_ip" {
  count = length(var.ssh_allowed_cidrs) > 0 ? 0 : 1
  url   = "https://checkip.amazonaws.com"
}

# Canonical's official Ubuntu 24.04 LTS (noble) x86_64 AMI.
data "aws_ssm_parameter" "ubuntu_2404" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# ------------------------------------------------------------------------------
# Network: the account's default VPC by default (this account is at its VPC
# quota), or a small dedicated VPC with one public subnet if create_vpc = true.
# ------------------------------------------------------------------------------
data "aws_vpc" "default" {
  count   = var.create_vpc ? 0 : 1
  default = true
}

data "aws_subnet" "default" {
  count             = var.create_vpc ? 0 : 1
  vpc_id            = data.aws_vpc.default[0].id
  availability_zone = var.availability_zone
  default_for_az    = true
}

resource "aws_vpc" "this" {
  count                = var.create_vpc ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  tags   = { Name = var.name }
}

resource "aws_subnet" "public" {
  count                   = var.create_vpc ? 1 : 0
  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name}-public" }
}

resource "aws_route_table" "public" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }
  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  count          = var.create_vpc ? 1 : 0
  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

locals {
  vpc_id    = var.create_vpc ? aws_vpc.this[0].id : data.aws_vpc.default[0].id
  subnet_id = var.create_vpc ? aws_subnet.public[0].id : data.aws_subnet.default[0].id
}

# SSH only from the operator's IP. Redis/RE ports are NOT exposed; reach them
# with `ssh -L` (see outputs.ssh_tunnel_command).
resource "aws_security_group" "vm" {
  name        = "${var.name}-vm"
  description = "SSH from operator IP only"
  vpc_id      = local.vpc_id
  tags        = { Name = "${var.name}-vm" }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each          = toset(local.ssh_cidrs)
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  description       = "SSH from operator"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ------------------------------------------------------------------------------
# SSH key (generated; private key written locally, git-ignored).
# ------------------------------------------------------------------------------
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "this" {
  key_name   = var.name
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "ssh_private_key" {
  filename        = "${path.module}/.keys/${var.name}"
  content         = tls_private_key.ssh.private_key_openssh
  file_permission = "0600"
}

# ------------------------------------------------------------------------------
# The VM
# ------------------------------------------------------------------------------
resource "aws_instance" "vm" {
  ami           = data.aws_ssm_parameter.ubuntu_2404.value
  instance_type = var.instance_type
  subnet_id     = local.subnet_id
  # Default-VPC subnets auto-assign a public IP; be explicit for custom ones.
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.vm.id]
  key_name                    = aws_key_pair.this.key_name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    delete_on_termination = true
    encrypted             = true
    tags                  = merge(local.common_tags, { Name = "${var.name}-root" })
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = var.name }

  lifecycle {
    # Don't replace the VM just because Canonical published a newer AMI.
    ignore_changes = [ami]
  }
}

# ------------------------------------------------------------------------------
# Installer: copy the self-contained bundle to the VM and run it. The exact same
# bundle/script is what a customer runs on their own bare-metal Ubuntu 24 box.
# ------------------------------------------------------------------------------
resource "terraform_data" "installer" {
  count = var.run_installer ? 1 : 0
  triggers_replace = [aws_instance.vm.id, local.bundle_hash, local.installer_env_s,
  local.license_path == "" ? "" : filesha256(local.license_path)]

  connection {
    type        = "ssh"
    host        = aws_instance.vm.public_ip
    user        = "ubuntu"
    private_key = tls_private_key.ssh.private_key_openssh
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = ["cloud-init status --wait >/dev/null 2>&1 || true", "mkdir -p /home/ubuntu/redis-flex-kind"]
  }

  provisioner "file" {
    source      = "${local.bundle_dir}/"
    destination = "/home/ubuntu/redis-flex-kind"
  }

  # License is uploaded outside the bundle so it never lands in the repo.
  provisioner "file" {
    source      = local.license_path == "" ? "/dev/null" : local.license_path
    destination = local.license_remote
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 600 ${local.license_remote}",
      "chmod +x /home/ubuntu/redis-flex-kind/redis-flex-kind.sh",
      # The script tees its own output to /var/log/redis-flex-kind.log
      "sudo env ${local.installer_env_s} /home/ubuntu/redis-flex-kind/redis-flex-kind.sh install",
    ]
  }
}
