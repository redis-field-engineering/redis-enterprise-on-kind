# Reference run (AWS r6id.4xlarge, 2026-10-07)

A snapshot of a working install, collected from the VM before it was destroyed.
Use it to compare against your own install. Passwords and license keys are removed.

| File | Contents |
| --- | --- |
| `host-and-versions.txt` | OS/kernel, tool versions, disks and mounts, fstab, docker `daemon.json`, sysctls, THP, systemd units, `nofile` inside the kind node |
| `kubectl-state.txt` | Nodes, REC/REDB/pods/PVCs/services, PV/StorageClass, helm release |
| `rendered/` | The manifests exactly as rendered by `redis-flex-kind.sh` with default settings on this host |
| `rec-live.yaml`, `redb-live.yaml` | Live REC and REDB objects, including operator-filled defaults and status |
| `rest-*.json` | RE REST API: database, node (flash size and driver), cluster name, cluster policy, license (trial) |
| `rladmin-status.txt` | `rladmin status extra all` |

## Environment

- **Instance:** r6id.4xlarge, 16 vCPU, 123 GiB usable RAM, 1× 884.8 GiB NVMe instance
  store (ext4, 870 GiB), 200 GB gp3 root.
- **Software:** Ubuntu 24.04.5, kernel 7.0 (aws), Docker CE, kind v0.33.0
  (kindest/node v1.36.4), Redis Enterprise operator 8.2.0-18 (RS 8.2.0-78).
- **REC:** 1 node, 12 CPU / 105 Gi, Flex `speedb`, flash PV 843 Gi.
- **DB `kvcache`:** 687 GiB total = 64 GiB RAM + 623 GiB flash, 4 shards,
  `allkeys-lru`, no persistence, Redis 8.2.1.

## Write test (flash tier exercised)

Run on the VM against `127.0.0.1:12000` (the kind host port):

```bash
docker run --rm --network host redislabs/memtier_benchmark:latest \
  -s 127.0.0.1 -p 12000 -a "$PW" --protocol=redis --ratio=1:0 \
  --data-size=102400 --key-pattern=P:P --key-maximum=1000000 --requests=allkeys \
  -t 4 -c 8 --pipeline=4 --hide-histogram
```

| Metric | Result |
| --- | --- |
| Written | ~992k keys × 100 KB ≈ 95 GB (more than the 64 GiB RAM tier) in 56 s |
| Throughput | 19.5k SET/s ≈ 1.9 GB/s |
| Latency | p50 5.1 ms, p99 41 ms, p99.9 208 ms (pipeline 4, 32 connections) |
| Placement right after the run | 788k objects in RAM, 204k on flash, 26 GB used on `/mnt/redis-flex` |

## Sizing probes (`POST /v1/bdbs?dry_run=1`, 4 shards)

| total / RAM (GiB) | Result |
| --- | --- |
| 640 / 64, 680 / 64, 690 / 64, 690 / 32, 680 / 16 | accepted |
| 700 / 64, 760 / 64, 800 / 64, 864 / 64 | `Cannot allocate nodes for shards` |
| 690 / 100 | rejected (RAM tier is over 88% of node RAM) |
| 700 / 64 with `bigstore_provision_node_threshold_p = 0` | accepted (the policy was restored to 12 afterwards) |
| 750 / 64 with `bigstore_provision_node_threshold_p = 0` | rejected |

## Verification run (2026-10-08): both flash modes, reboots, restarts

Same instance type, run from scratch with the updated bundle.

| Scenario | Result |
| --- | --- |
| `terraform apply` from scratch (managed mode, auto-detected instance-store NVMe, ext4) | installed in about 5 minutes; DB 687 GB total / 64 GB RAM; smoke test OK |
| Reboot, managed mode, flash nearly empty | mount, Docker and kind came back; the operator re-created the cluster and DB unattended in about 80 s |
| Switch to an **existing mount**: NVMe re-formatted xfs and mounted at `/data` via fstab, plus unrelated `/data/other-app` data | `FLEX_DIR=/data/redis-flex` install OK (DB 685 GB / 64 GB RAM); `other-app` untouched |
| Guard rails on the real host | refused: no `FLEX_DIR`/`NVME_DEVICE` with no blank disk; `NVME_DEVICE` (even with `FORCE_FORMAT=1`) on the mounted disk; non-empty `FLEX_DIR`; `FLEX_DIR` on `/` (nothing created) |
| 80 GB write, existing mode (xfs) | 24.7k SET/s ≈ 2.5 GB/s, p50 4.8 ms, p99 18 ms; 211k objects on flash, all under `/data/redis-flex`; root disk untouched |
| Laptop through SSH tunnel | `PING` → `PONG`, admin UI 200 |
| **Reboot with ~30 GB of stale flash, before the fix** | ❌ the DB was never re-created: `Cannot allocate nodes for shards`. Fixed by the `flex-flash-cleanup` init container. |
| Reboot with 16 GB on flash, after the fix | ✅ the init container cleared stale shards; DB answering 137 s after SSH was back, unattended |
| REC spec change (`REC_CPU` 12 → 11) with data on flash | ✅ fully handled by `install`: stuck-terminating pod force-deleted, cluster recovery triggered, DB recovered with `rladmin recover all`; about 11 minutes |
