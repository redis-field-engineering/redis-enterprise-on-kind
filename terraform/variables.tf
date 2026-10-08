variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use (null = default credential chain)."
  type        = string
  default     = null
}

variable "availability_zone" {
  description = "AZ for the subnet/instance. Must offer var.instance_type."
  type        = string
  default     = "us-east-1a"
}

variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "redis-flex-kind"
}

# --- Mandatory cost-allocation tags -------------------------------------------
variable "owner" {
  description = "owner tag: person responsible for the resources (first_name_last_name, lowercase)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+(_[a-z0-9]+)*$", var.owner)) && length(var.owner) <= 63
    error_message = "owner must be lowercase a-z0-9 with single underscores."
  }
}

variable "team" {
  description = "team tag: team responsible for the resources (lowercase, underscores)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+(_[a-z0-9]+)*$", var.team)) && length(var.team) <= 63
    error_message = "team must be lowercase a-z0-9 with single underscores."
  }
}

variable "extra_tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}

# --- Compute ------------------------------------------------------------------
variable "instance_type" {
  description = "x86 instance with ~1TB local NVMe and enough RAM for a 64GB-RAM Flex DB. r6id.4xlarge = 16 vCPU / 128 GiB / 1x950 GB NVMe."
  type        = string
  default     = "r6id.4xlarge"
}

variable "root_volume_size_gb" {
  description = "Root EBS (gp3) size. Holds docker images, kind node, and RE persistence."
  type        = number
  default     = 200
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to SSH. Empty = auto-detect this machine's public IP (/32)."
  type        = list(string)
  default     = []
}

variable "create_vpc" {
  description = "Create a dedicated VPC. false = use the region's default VPC/subnet."
  type        = bool
  default     = false
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.42.1.0/24"
}

# --- Installer ----------------------------------------------------------------
variable "run_installer" {
  description = "Upload ../redis-flex-kind and run `redis-flex-kind.sh install` over SSH after the instance boots."
  type        = bool
  default     = true
}

variable "redis_license_file" {
  description = "Local path to a Redis Enterprise license file uploaded to the VM (skipped if missing). Must be issued for rec.redis.svc.cluster.local. Empty = built-in trial (30 days, 4 shards)."
  type        = string
  default     = "~/.config/redis/license.txt"
}

variable "installer_env" {
  description = "Env overrides passed to redis-flex-kind.sh (see redis-flex-kind/config.env)."
  type        = map(string)
  default     = {}
}
