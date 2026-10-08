# Runbook: AWS EC2 test box with Terraform

Use this to stand up a disposable test environment. `terraform apply` creates one
EC2 instance and installs everything on it (about 15 minutes). `terraform destroy`
removes it all.

**What gets created**
- One `r6id.4xlarge`: 16 vCPU, 128 GiB RAM, 1× 950 GB NVMe instance store,
  Ubuntu 24.04 x86_64, 200 GB gp3 root.
- A security group that allows SSH **only from your current public IP**. No Redis
  ports are opened; you reach them through an SSH tunnel.
- A generated SSH key (written to `terraform/.keys/`, git-ignored) and an EC2 key
  pair.
- The account's default VPC is used. Set `create_vpc = true` to get a dedicated one.
- Every resource is tagged `owner`, `team` and `project`.

**Cost:** about $1.21/hour for the instance (us-east-1 on-demand), plus about
$0.03/hour for the volume and public IP. A 2-hour test costs about $2.50;
leaving it up overnight costs about $20.

## Prerequisites

- Terraform >= 1.5 and the AWS CLI, with credentials that can create EC2/VPC
  resources (`aws sts get-caller-identity` works).
- Optional: a Redis Enterprise license issued for `rec.redis.svc.cluster.local`.
  Without one, the 30-day / 4-shard trial is used, which is enough for this setup.

## 1. Configure

```bash
git clone https://github.com/redis-field-engineering/redis-enterprise-on-kind.git
cd redis-enterprise-on-kind/terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. Only `owner` and `team` are required:

```hcl
owner = "first_last"        # lowercase, a-z0-9 and single underscores
team  = "my_team"

# Optional:
# region             = "us-east-1"
# availability_zone  = "us-east-1a"
# instance_type      = "r6id.4xlarge"           # or r8id.4xlarge; bigger NVMe = bigger DB
# redis_license_file = "~/.config/redis/license.txt"   # skipped if the file doesn't exist
# installer_env      = { DB_RAM = "64GB", DB_SHARDS = "4" }   # any redis-flex-kind/config.env setting
```

## 2. Create

```bash
terraform init
terraform apply
```

Terraform creates the instance, waits for cloud-init, uploads `../redis-flex-kind/`
and runs `redis-flex-kind.sh install` over SSH. The output streams to your terminal
and ends with the database password and a `PONG` / `OK` / `world` smoke test.

The NVMe is found automatically (EC2 instance store), formatted and mounted at
`/mnt/redis-flex`.

## 3. Connect

```bash
terraform output -raw ssh_command          # shell on the VM
$(terraform output -raw ssh_tunnel_command) # forwards 12000 / 9443 / 8443 to localhost (leave running)
```

In another terminal:

```bash
SSH=$(terraform output -raw ssh_command)
PW=$($SSH "kubectl -n redis get secret redb-kvcache -o jsonpath='{.data.password}' | base64 -d")
redis-cli -h 127.0.0.1 -p 12000 -a "$PW" PING
```

| What | Where |
| --- | --- |
| Redis Flex database | `127.0.0.1:12000` |
| RE admin UI | `https://localhost:8443` (user and password are in secret `rec`) |
| RE REST API | `https://localhost:9443` |

On the VM, `sudo redis-flex-kind/redis-flex-kind.sh status` prints sizes, the
license and the password.

## 4. Change things

| Task | How |
| --- | --- |
| Change DB settings | Edit `installer_env` in `terraform.tfvars`, then `terraform apply`. This re-runs the (idempotent) installer. For a clean rebuild with new sizes, run `uninstall` on the VM first. |
| Change the installer | Edit files in `redis-flex-kind/`, then `terraform apply`. A change to the bundle triggers a re-run. |
| Infrastructure only | Set `run_installer = false`, then run the bundle yourself (see the [bare-metal runbook](runbook-bare-metal.md)). |
| Your IP changed | `terraform apply`. The SSH rule is re-detected. |

**Reboot vs stop.** Rebooting is safe; the DB comes back empty in about 1.5 minutes (it's a cache). **Stopping and starting the instance wipes
the NVMe instance store.** The boot unit re-creates the filesystem, but the
database data is gone. On the VM, run
`sudo redis-flex-kind/redis-flex-kind.sh uninstall` and then `... install` to
rebuild. Alternatively, from your machine run
`terraform apply -replace='terraform_data.installer[0]'`. A plain `terraform apply`
won't re-run the installer, because nothing it watches has changed.

## 5. Destroy

```bash
terraform destroy
```

This removes the instance, root volume, security group, key pair and local key
file.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `VpcLimitExceeded` | Keep the default `create_vpc = false`. |
| SSH timeout | Your public IP changed. Run `terraform apply`. |
| `InsufficientInstanceCapacity` | Try another `availability_zone` or `instance_type = "r8id.4xlarge"`. |
| Installer failed partway | `terraform apply` re-runs it (the failed step is tainted). The log is at `/var/log/redis-flex-kind.log` on the VM. |
| Anything in Redis/k8s | See the troubleshooting table in the [bare-metal runbook](runbook-bare-metal.md#troubleshooting). |
