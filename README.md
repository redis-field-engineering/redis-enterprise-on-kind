# Redis Enterprise on kind with Redis Flex (NVMe)

Run a single-node **Redis Enterprise for Kubernetes** cluster inside **kind** on one
Ubuntu 24.04 box with a local NVMe disk, and create a **Redis Flex** database whose
RAM tier is backed by the NVMe flash tier. Example: 64 GiB RAM + ~620 GiB flash
(~690 GiB total) on a 128 GiB RAM / 950 GB NVMe machine.

Intended use: a large, cheap-per-GB key/value tier on a single server, e.g. a
KV-cache backend (LMCache's Redis connector for vLLM) running next to GPU hosts.

```
 laptop / app host                 Ubuntu 24.04 host (bare metal or EC2)
 ─────────────────                 ───────────────────────────────────────────────
                                   /dev/nvmeXn1 ─ ext4 ─> /mnt/redis-flex
 ssh -L 12000 ──────────────────>  127.0.0.1:12000 ┐  (kind extraPortMappings)
 ssh -L 9443  ──────────────────>  127.0.0.1:9443  ├─> kind node (docker)
 ssh -L 8443  ──────────────────>  127.0.0.1:8443  ┘     ├─ NodePort svcs -> rec-0
                                                         ├─ redis-enterprise-operator
                                                         └─ REC "rec" (1 pod)
                                                              ├─ PV: /mnt/redis-flex/flash (Flex, speedb)
                                                              └─ REDB "kvcache" :12000
                                                                   64 GiB RAM + ~620 GiB flash
```

## Repository layout

| Path | What |
| --- | --- |
| [`redis-flex-kind/`](redis-flex-kind) | **The portable bundle.** Copy this directory to any Ubuntu 24.04 x86_64 host with an NVMe and run one command. |
| [`redis-flex-kind/redis-flex-kind.sh`](redis-flex-kind/redis-flex-kind.sh) | Idempotent installer (`install`, or individual steps, `status`, `test`, `uninstall`). |
| [`redis-flex-kind/config.env`](redis-flex-kind/config.env) | All tunables (versions, device, sizes, ports). Override any of them via env vars. |
| [`redis-flex-kind/manifests/`](redis-flex-kind/manifests) | Templated kind config, Flex StorageClass/PV, REC, REDB and NodePort services. |
| [`terraform/`](terraform) | Optional: an AWS EC2 test box (r6id.4xlarge, Ubuntu 24.04) that runs the same bundle. |
| [`docs/runbook-bare-metal.md`](docs/runbook-bare-metal.md) | Step-by-step runbook for an existing server (NVMe already mounted, or blank). |
| [`docs/runbook-aws-terraform.md`](docs/runbook-aws-terraform.md) | Step-by-step runbook for the AWS test box. |
| [`docs/reference-run/`](docs/reference-run) | Snapshot of a working install: rendered manifests, live REC/REDB, REST outputs, logs, write-test and sizing results. |

## Quick start

Pick the runbook that matches what you have:

| You have | Runbook |
| --- | --- |
| An Ubuntu 24.04 server with an NVMe, either already mounted or blank | **[docs/runbook-bare-metal.md](docs/runbook-bare-metal.md)** |
| An AWS account and want a throwaway test box | **[docs/runbook-aws-terraform.md](docs/runbook-aws-terraform.md)** |

The short version for bare metal, with the NVMe already mounted at `/data`:

```bash
scp -r redis-flex-kind/ user@server: && ssh user@server
sudo FLEX_DIR=/data/redis-flex ./redis-flex-kind/redis-flex-kind.sh plan      # shows what it will do
sudo FLEX_DIR=/data/redis-flex ./redis-flex-kind/redis-flex-kind.sh install
```

For a blank NVMe that the installer should format, use `NVME_DEVICE=/dev/nvme1n1`
instead of `FLEX_DIR`.

## Requirements

- Ubuntu 24.04 LTS, x86_64, root (sudo).
- A local NVMe for Redis Flex, in one of two forms:
  - **Already formatted and mounted** (`FLEX_DIR=<empty dir on it>`). Never formatted.
    The dir must be on a local ext4/xfs filesystem other than root, and must be
    empty or previously prepared by this tool.
  - **Blank** (`NVME_DEVICE=/dev/nvmeXn1`). Formatted as ext4 only if it has no
    filesystem; a disk that already has one is refused (unless `FORCE_FORMAT=1`).
  - If neither is set, the single blank, unused NVMe is used if there is exactly
    one (the EC2 case). Otherwise the installer stops and asks.
- RAM: the database RAM tier + ~25% headroom. 128 GB RAM handles a 64 GB RAM tier.
- Flash: Redis Enterprise provisions at most about **80% of the flash filesystem** as
  database size (RAM + flash). See [Sizing](#sizing).
- Outbound internet (apt, Docker Hub, `helm.redis.io`, `dl.k8s.io`, GitHub).
- Optional: a Redis Enterprise license **issued for the cluster name
  `rec.redis.svc.cluster.local`** (see [Licensing](#licensing)). Without one, the
  built-in trial is used (30 days, 4 shards, Flex included). That is enough for this
  setup.

## What `install` does

Each step is also a subcommand, and every step is idempotent.

| Step | Does |
| --- | --- |
| `plan` | (Not part of `install`.) Prints the flash mode, path and computed sizes; changes nothing. |
| `preflight` | Checks OS, arch and RAM, and lists disks and the chosen flash mode. |
| `host` | Installs Docker CE, kind, kubectl and helm (pinned). Sets the Docker default `nofile` ulimit to 1,048,576, sysctls (`vm.overcommit_memory=1`, inotify limits, somaxconn), and disables THP and swap. |
| `nvme` | **Existing mount:** validates and prepares `FLEX_DIR`. **Managed disk:** formats it (only if blank) and mounts it at `/mnt/redis-flex` via fstab. Both modes install `redis-flex-boot.service` and order Docker after the flash mount. In managed mode the boot unit also re-creates the filesystem if a cloud instance-store disk comes back blank. The choice is saved to `/var/lib/redis-flex-kind/state.env`. |
| `kind` | Creates the single-node kind cluster. The flash dir and a host persistence dir are mounted in, and ports are mapped to `LISTEN_ADDRESS` (default `127.0.0.1`). |
| `operator` | Helm-installs `redis/redis-enterprise-operator`, creates the Flex StorageClass and static local PV, and creates the license secret. |
| `rec` | Creates or updates the `RedisEnterpriseCluster` (1 node, Flex/speedb on the flash PV, flash-cleanup init container). Waits until it is `Running` and fully rolled out, handling single-node rollouts (see below). Warns if the license was not accepted. |
| `db` | Sanity-checks sizes, creates the Flex `RedisEnterpriseDatabase` plus NodePort services, and waits until the DB answers `PING` on the host port. |
| `status` | Prints REC/REDB/pods, DB flash/RAM sizes from the REST API, license info, and the password. |
| `test` | Runs `PING`/`SET`/`GET` through the host port. |
| `recover` | (Not part of `install`.) Brings a stuck single-node cluster or database back: cluster recovery if the REC isn't `Running`, then `rladmin recover all`. |
| `uninstall` | Deletes the kind cluster and its Redis data (only inside the flash dir this tool prepared). The disk stays mounted. |

## What had to be adapted (and why)

Nothing in Redis Enterprise itself was modified. Everything below is Kubernetes,
host, or configuration glue, and it all lives in this repo:

1. **Single-node REC (`spec.nodes: 1`).** The docs list 3 nodes as the minimum for
   production. The operator accepts 1, and it works for a single-box cache. There
   is no HA: lose the host, lose the data.
2. **Flash storage on kind.** The REC needs a StorageClass for the Flex volume. kind
   has no local-NVMe provisioner, so the installer mounts the flash directory on the
   host's NVMe filesystem into the kind node (`extraMounts`), and creates a
   `kubernetes.io/no-provisioner` StorageClass plus one static local PV
   (`manifests/flex-storage.yaml.tpl`), sized to 97% of free space. The REC's
   `redisOnFlashSpec.storageClassName` points at it. The REC's persistent
   (metadata) volume uses kind's default `local-path` class, backed by a host dir
   on the root disk.
3. **Open files limit.** Redis Enterprise needs `nofile >= 100000`. containerd 2.x
   gives containers 1024 by default. The installer sets Docker's `default-ulimits`,
   so the kind node (and pods in it) get 1,048,576.
4. **CPU sizing.** The REC pod uses guaranteed QoS (requests = limits). The operator,
   services rigger and kube-system pods already request about 2.3 CPU, so the REC
   is auto-sized to `nproc - 4` CPUs and 85% of host RAM.
5. **Exposing the DB.** The operator only creates ClusterIP/headless/LoadBalancer
   services. The installer adds its own NodePort services that select the REC pod
   (`manifests/expose.yaml.tpl`). kind maps those ports to `127.0.0.1` on the host.
6. **Licensing.** On Kubernetes the operator always names the RE cluster
   `<rec>.<namespace>.svc.cluster.local`. That suffix is hard-coded and does not
   follow the k8s DNS domain. A license bound to any other name or pattern (for
   example `*.example.com`) is rejected with `License cluster name does not match`,
   and the REC keeps running on the trial. The installer detects this and warns.
   See [Licensing](#licensing).
7. **Sizing to what RE will provision.** See [Sizing](#sizing). The default
   database size is auto-computed as 79% of the free flash space.
8. **Stale flash after restarts.** Redis Flex doesn't use flash for durability.
   When the REC pod restarts (host reboot, crash, eviction), the operator recovers
   the cluster and re-creates the database **empty** (persistence is off; it's a
   cache). The old shards' speedb files stay on the NVMe and count against free
   flash, so the re-create fails with `Cannot allocate nodes for shards` and the
   database never comes back. To prevent this, an init container on the REC pod
   (`flex-flash-cleanup`, see `manifests/rec.yaml.tpl`) deletes
   `/opt/flash/bigstore-*` before Redis Enterprise starts.
9. **Single-node pod restarts.** RE's preStop hook tries to demote the node so
   another one can take over. With `nodes: 1` that can never succeed, and the
   operator forces a termination grace period of **1 year**. Setting
   `terminationGracePeriodSeconds` through the REC is ignored. So a graceful
   `kubectl delete pod rec-0` or drain hangs; use
   `kubectl -n redis delete pod rec-0 --grace-period=0 --force`. During `rec`, the
   script does this automatically after `REC_FORCE_TERMINATE_AFTER_SECONDS` (180 s).
   A host reboot isn't affected (the pod is simply killed).
10. **Single-node rolling updates.** When the REC spec changes (resources, image,
    init containers...), the operator restarts the only pod and waits for it to
    *join* the cluster, which it can't do alone (it logs `No pod has been labeled
    as master pod yet`). `rec` handles this automatically: it force-deletes the
    stuck pod (see 9), and if the REC sits in `RunningRollingUpdate` with no
    bootstrapped pod for 3 minutes, it sets the operator's documented
    `spec.clusterRecovery: true`. After that kind of recovery the database comes
    back in RE state `recovery`, so `db` runs `rladmin recover all`, as the
    operator's recovery procedure prescribes. A config change on a single node
    takes about 10 minutes end to end, and the cache is emptied.
    `redis-flex-kind.sh recover` runs the same steps by hand.
11. **Boot ordering.** `redis-flex-boot.service` runs before Docker. In managed
    mode it re-creates the filesystem if the disk came back blank; in both modes it
    refuses to continue if the flash path resolves to the root filesystem. A Docker
    drop-in orders Docker after the flash mount, so the kind node never binds an
    unmounted (empty) directory.

## Sizing

Measured with the REST API `POST /v1/bdbs?dry_run=1` on an r6id.4xlarge:
870 GiB ext4 on the NVMe, REC pod with 12 CPU / 105 Gi.

| Limit | Value | Why |
| --- | --- | --- |
| Total DB size (`memorySize` = RAM + flash) | **≈ 690 GiB max** (700 rejected) | RE keeps 12% of flash free (cluster policy `bigstore_provision_node_threshold_p`) and budgets extra flash for speedb space amplification. Even with that policy set to 0, 750 GiB is rejected. |
| RAM tier (`rofRamSize`) | ≈ 92 GiB max | 88% of the node's RAM (`redis_provision_node_threshold_p: 12`). |
| Shards | 4 on the trial license | Set by `DB_SHARDS`. |

Rejections show up as `admission webhook ... denied the request: Cannot allocate
nodes for shards`. Rules of thumb:

- Total DB size ≈ **0.79 × NVMe filesystem size**. For ~800 GiB of flash you need
  roughly a 1.1–1.2 TB NVMe. Examples: `r6id.8xlarge` (1.9 TB, 256 GiB RAM), or
  `i4i.4xlarge` (3.75 TB, 128 GiB RAM).
- RAM tier ≤ ~0.85 × REC memory. 64 GiB RAM / 690 GiB total is a ~9% RAM ratio,
  which Redis Flex accepts.
- Defaults: `DB_RAM=64GB`, `DB_MEMORY` auto (79% of the filesystem), `DB_SHARDS=4`,
  eviction `allkeys-lru`, persistence off (a cache).

## Licensing

- **No license:** trial mode. 30 days from REC creation, 4 shards, all features
  including Flex (`bigstore`).
- **With a license:** pass `REDIS_LICENSE_FILE=/path/license.txt`. The installer
  stores it in secret `rec-license` and sets `spec.licenseSecretName`. The license
  must be issued for **`rec.redis.svc.cluster.local`**, i.e.
  `<REC_NAME>.<NAMESPACE>.svc.cluster.local`. A license made for a VM cluster with
  a different FQDN pattern won't apply. Check with:

  ```bash
  kubectl -n redis get rec rec -o jsonpath='{.status.licenseStatus}'; echo
  ```

## Versions

Pinned in `config.env`:

| Component | Version |
| --- | --- |
| Redis Enterprise operator (helm chart) | 8.2.0-18 (RS 8.2.0-78) |
| kind / node image | v0.33.0 / kindest/node v1.36.4 (operator supports k8s 1.33–1.36) |
| kubectl / helm | v1.36.4 / v4.3.0 |
| Database | Redis 8.2, Flex (`bigStoreDriver: speedb`) |

## Troubleshooting

```bash
sudo tail -f /var/log/redis-flex-kind.log
kubectl -n redis get rec,redb,pods,pvc
kubectl -n redis describe rec rec
kubectl -n redis logs deploy/redis-enterprise-operator -c redis-enterprise-operator --tail=100
kubectl -n redis exec -it rec-0 -c redis-enterprise-node -- rladmin status extra all
```

| Symptom | Fix |
| --- | --- |
| `rec-0` Pending, `Insufficient cpu` | Lower `REC_CPU`, then re-run `rec`. |
| REC license shows `trial` | The operator log says `License cluster name does not match`. Get a license for `rec.redis.svc.cluster.local`. |
| `nvme` step refuses the disk | The disk already has a filesystem. If it's mounted, use `FLEX_DIR=<empty dir on it>`; otherwise point `NVME_DEVICE` at the right disk, or set `FORCE_FORMAT=1`. |
| `Cannot allocate nodes for shards` | The DB is too big for the RAM or flash. Lower `DB_MEMORY` / `DB_RAM` (see [Sizing](#sizing)), then re-run `db`. |
| DB stuck `pending` | `kubectl -n redis describe redb kvcache`: usually the shard limit (trial = 4). |
| REC stuck in `RunningRollingUpdate`, `rec-0` 1/2 ready | Single-node rollout. `install` handles it automatically, or run `sudo ./redis-flex-kind/redis-flex-kind.sh recover`. |
| REDB / `rladmin status` shows the DB in `recovery`; the operator logs `Database changes won't be applied due to its state` | `sudo ./redis-flex-kind/redis-flex-kind.sh recover` (runs `rladmin recover all`). |
| `rec-0` stuck `Terminating` | Expected on a single node (RE's preStop can't demote the only node). `kubectl -n redis delete pod rec-0 --grace-period=0 --force`; `rec` does this automatically. |
| After a reboot the DB is missing and the operator logs `Cannot allocate nodes for shards` | Stale flash data on a pre-cleanup install. Re-run `install` (it adds the cleanup init container). |
