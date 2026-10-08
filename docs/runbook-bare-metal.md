# Runbook: existing Ubuntu 24.04 server with NVMe

Use this for a bare-metal server (or any VM) you already have. It takes about 15
minutes, and the installer is safe to re-run at any point.

**You need:**
- Ubuntu 24.04 LTS on x86_64, with sudo.
- A local NVMe disk for Redis Flex, either already formatted and mounted (Option A
  below) or blank (Option B).
- RAM: 128 GB is comfortable for a 64 GB RAM tier.
- Outbound internet access to apt, Docker Hub, `helm.redis.io`, `dl.k8s.io` and
  GitHub.

## 1. Copy the bundle to the server

```bash
git clone https://github.com/redis-field-engineering/redis-enterprise-on-kind.git
scp -r redis-enterprise-on-kind/redis-flex-kind/ user@server:
ssh user@server
```

## 2. Look at your disks

```bash
lsblk -o NAME,SIZE,MODEL,FSTYPE,MOUNTPOINT
```

Then pick **one** of the two options below.

### Option A: the NVMe is already formatted and mounted (most common)

Example: `nvme1n1` (ext4 or xfs) is mounted at `/data` through `/etc/fstab`.
Choose an **empty directory** on that mount and dedicate it to Redis Flex:

```bash
FLASH="FLEX_DIR=/data/redis-flex"
```

The installer never formats or remounts anything in this mode. It checks that
the directory:
- is on a local filesystem other than root;
- is empty, or was already prepared by this tool.

The directory's contents are deleted on `uninstall`.

### Option B: the NVMe is blank and the installer should format it

```bash
FLASH="NVME_DEVICE=/dev/nvme1n1"     # ALL DATA ON THIS DISK WILL BE LOST
```

The installer formats the disk as ext4 (label `redisflex`), but only if it has
no filesystem; it refuses a disk that already has one. It mounts the disk at
`/mnt/redis-flex` and adds it to `/etc/fstab`.

## 3. Check the plan (changes nothing)

```bash
sudo $FLASH ./redis-flex-kind/redis-flex-kind.sh plan
```

This shows the mode, the flash path and (in Option A) the sizes that will be used:

```
flash mode : existing
flash path : /data/redis-flex (existing mount; never formatted)
REC        : cpu=12 memory=105Gi flashDiskSize=843Gi
database   : kvcache total=687GB ram=64GB shards=4 port 127.0.0.1:12000
```

Defaults. Override any of them on the command line the same way, for example
`sudo $FLASH DB_RAM=48GB ./redis-flex-kind/redis-flex-kind.sh plan`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `DB_RAM` | `64GB` | RAM tier of the database |
| `DB_MEMORY` | 79% of the free flash space | Total size (RAM + flash). Redis Enterprise won't provision more than about 80% of the flash filesystem. |
| `DB_SHARDS` | `4` | The trial license allows 4 shards |
| `DB_PORT` / `HOST_DB_PORT` | `12000` | Database port |
| `LISTEN_ADDRESS` | `127.0.0.1` | Host address the DB, API and UI ports bind to |
| `REDIS_LICENSE_FILE` | *(trial)* | License file. It must be issued for `rec.redis.svc.cluster.local`. |

## 4. Install

```bash
sudo $FLASH ./redis-flex-kind/redis-flex-kind.sh install
```

The run ends by printing the database password and a smoke test (`PONG`, `OK`,
`world`). The full log is at `/var/log/redis-flex-kind.log`.

## 5. Connect

On the server:

```bash
sudo ./redis-flex-kind/redis-flex-kind.sh status          # sizes, license, password
redis-cli -h 127.0.0.1 -p 12000 -a '<password>' PING
```

From your workstation, open a tunnel, then connect to localhost:

```bash
ssh -N -L 12000:127.0.0.1:12000 -L 9443:127.0.0.1:9443 -L 8443:127.0.0.1:8443 user@server
```

| What | Where | Credentials |
| --- | --- | --- |
| Redis database | `127.0.0.1:12000` | `kubectl -n redis get secret redb-kvcache -o jsonpath='{.data.password}' \| base64 -d` |
| RE admin UI | `https://localhost:8443` | `kubectl -n redis get secret rec -o jsonpath='{.data.username}' \| base64 -d` (and `.data.password`) |
| RE REST API | `https://localhost:9443` | same as the UI |

**Letting app servers connect directly** (for example vLLM/LMCache hosts): reinstall
with `LISTEN_ADDRESS=<server private IP>`, and firewall port 12000 so only those
hosts can reach it:

```bash
sudo ./redis-flex-kind/redis-flex-kind.sh uninstall
sudo LISTEN_ADDRESS=10.0.0.5 ./redis-flex-kind/redis-flex-kind.sh install
```

Clients then use `redis://:<password>@10.0.0.5:12000`.

## 6. Day-2 operations

| Task | Command |
| --- | --- |
| Status | `sudo ./redis-flex-kind/redis-flex-kind.sh status` |
| Smoke test | `sudo ./redis-flex-kind/redis-flex-kind.sh test` |
| Re-run / repair | `sudo ./redis-flex-kind/redis-flex-kind.sh install` (idempotent) |
| DB not coming back | `sudo ./redis-flex-kind/redis-flex-kind.sh recover` |
| Change settings (e.g. `DB_RAM`) | `sudo ./redis-flex-kind/redis-flex-kind.sh uninstall`, then `sudo <VAR>=<value> ./redis-flex-kind/redis-flex-kind.sh install`. Changing the cluster in place (e.g. `REC_CPU`) also works through `install`, but on a single node it takes about 10 minutes and empties the cache. |
| Remove everything | `sudo ./redis-flex-kind/redis-flex-kind.sh uninstall` (deletes the kind cluster and DB data; the disk stays mounted) |
| Reboot | Safe. Docker waits for the flash mount, and kind and Redis Enterprise come back on their own. About 1.5 minutes after Docker starts, the DB answers again **empty**: it's a cache with persistence off, and stale flash data is cleared automatically. |

The flash choice (`FLEX_DIR` or `NVME_DEVICE`) is remembered in
`/var/lib/redis-flex-kind/state.env` after the first run, so later commands
don't need it.

## Troubleshooting

| Message | Fix |
| --- | --- |
| `found 0 blank/unused NVMe disks` | Set `FLEX_DIR` (Option A) or `NVME_DEVICE` (Option B). |
| `... is not empty. FLEX_DIR must be an empty directory` | Pick a new, empty subdirectory on the NVMe mount. |
| `... is on the root filesystem` | `FLEX_DIR` must live on the NVMe mount, not on `/`. |
| `already has a xfs/ext4 filesystem ... Refusing to format` | The disk is in use. Use Option A with a directory on its mount point. |
| `DB_RAM ... must be smaller than DB_MEMORY` | The flash space is too small for the RAM tier. Use a bigger disk or a smaller `DB_RAM`. |
| `Cannot allocate nodes for shards` | The DB is larger than RE will provision. Lower `DB_MEMORY` or `DB_RAM`, then `uninstall` and `install`. |
| `rec-0` Pending, `Insufficient cpu` | Set a lower `REC_CPU` (default `nproc - 4`), then re-run `install`. |
| License shows `trial` | The license must be issued for `rec.redis.svc.cluster.local`. |
| REC stuck in `RunningRollingUpdate`, or DB stuck in `recovery` | `sudo ./redis-flex-kind/redis-flex-kind.sh recover` |

More detail, including sizing measurements and the reasoning behind each
workaround, is in the [main README](../README.md).
