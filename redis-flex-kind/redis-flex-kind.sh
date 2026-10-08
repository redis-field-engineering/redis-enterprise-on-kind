#!/usr/bin/env bash
# redis-flex-kind.sh - single-box Redis Enterprise (Redis Flex on local NVMe) on kind.
#
# Target: Ubuntu 24.04 x86_64 (bare metal or VM) with a dedicated local NVMe disk.
# Run as root from inside this directory's bundle (config.env + manifests/).
#
#   sudo ./redis-flex-kind.sh install      # everything below, in order (idempotent)
#
# Individual steps:
#   plan        show the flash mode, path and computed sizes; changes nothing
#   preflight   check OS / arch / RAM / disk
#   host        install docker, kind, kubectl, helm; tune sysctls, THP, ulimits
#   nvme        prepare flash storage: validate FLEX_DIR (existing mount), or format
#               (if blank) + mount NVME_DEVICE at $FLEX_MOUNT and persist across reboots
#   kind        create the kind cluster with NVMe + port mappings
#   operator    install the Redis Enterprise operator (helm) + flex storage class/PV
#   rec         create the RedisEnterpriseCluster (Flex enabled) and wait for Running
#   db          create the Flex database + localhost NodePort services, wait for active
#   status      print cluster/db state, credentials and connection info
#   test        PING / SET / GET against the database through the host port
#   recover     bring a stuck single-node cluster / database back (cluster recovery + rladmin recover)
#   uninstall   delete the kind cluster and its RE data (disk stays formatted + mounted)
set -Eeuo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="/var/lib/redis-flex-kind"
STATE_FILE="${WORK_DIR}/state.env"
STATE_VARS=(FLEX_DIR NVME_DEVICE FLEX_MOUNT LISTEN_ADDRESS HOST_DB_PORT HOST_API_PORT HOST_UI_PORT)
# Choices made on earlier runs (flash mode, listen address, ports) are remembered
# so later commands don't need them again. Explicitly set env vars always win;
# setting either FLEX_DIR or NVME_DEVICE replaces both remembered flash settings.
load_state() {
  [[ -r "${STATE_FILE}" ]] || return 0
  local line key val explicit_flash=0
  [[ -n "${FLEX_DIR+x}${NVME_DEVICE+x}" ]] && explicit_flash=1
  while IFS= read -r line; do
    key=${line%%=*}; val=${line#*=}
    [[ " ${STATE_VARS[*]} " == *" ${key} "* ]] || continue
    [[ $explicit_flash == 1 && ( $key == FLEX_DIR || $key == NVME_DEVICE ) ]] && continue
    [[ -n "${!key+x}" ]] && continue
    eval "${key}=${val}"   # values were written with printf %q
  done <"${STATE_FILE}"
}
save_state() {
  mkdir -p "${WORK_DIR}"
  local v; for v in "${STATE_VARS[@]}"; do printf '%s=%q\n' "$v" "${!v}"; done >"${STATE_FILE}"
}
load_state
# shellcheck source=config.env
source "${BUNDLE_DIR}/config.env"
RENDER_DIR="${WORK_DIR}/rendered"
LOG_FILE="/var/log/redis-flex-kind.log"
export KUBECONFIG="${WORK_DIR}/kubeconfig"

log()  { printf '\n\033[1;34m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

need_root() { [[ $EUID -eq 0 ]] || die "run as root (sudo $0 $*)"; }

# Render manifests/<name>.tpl -> $RENDER_DIR/<name> substituting only our variables.
render() {
  local name="$1" vars
  vars=$(grep -oE '\$\{[A-Z0-9_]+\}' "${BUNDLE_DIR}/manifests/${name}.tpl" | sort -u | tr '\n' ' ')
  mkdir -p "$RENDER_DIR"
  envsubst "$vars" <"${BUNDLE_DIR}/manifests/${name}.tpl" >"${RENDER_DIR}/${name}"
  echo "${RENDER_DIR}/${name}"
}

# Wait until "$@" succeeds, up to $timeout seconds.
wait_for() {
  local timeout="$1" desc="$2"; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start > timeout )) && die "timed out after ${timeout}s waiting for: $desc"
    sleep 10
  done
}

# ------------------------------------------------------------------------------
step_preflight() {
  log "Preflight"
  . /etc/os-release
  [[ "${ID}" == "ubuntu" && "${VERSION_ID}" == "24.04" ]] || warn "tested on Ubuntu 24.04, found ${PRETTY_NAME}"
  [[ "$(uname -m)" == "x86_64" ]] || die "x86_64 required, found $(uname -m)"
  local mem_gib; mem_gib=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  echo "CPUs: $(nproc)  RAM: ${mem_gib} GiB"
  (( mem_gib >= 32 )) || die "need at least 32 GiB RAM"
  lsblk -o NAME,SIZE,MODEL,FSTYPE,MOUNTPOINT | grep -v '^loop'
  resolve_flash
  echo "flash mode: ${FLASH_MODE}  flash path: ${FLASH_PATH}"
}

# ------------------------------------------------------------------------------
step_host() {
  log "Host packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg jq gettext-base xfsprogs e2fsprogs util-linux >/dev/null

  if ! command -v docker >/dev/null; then
    log "Installing Docker CE"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    . /etc/os-release
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      >/etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin >/dev/null
  fi

  # Redis Enterprise needs >= 100k open files; containerd 2.x defaults containers
  # to a 1024 soft limit. Raise the docker default so the kind node (and the pods
  # inside it) inherit a high limit.
  mkdir -p /etc/docker
  local want='{"default-ulimits":{"nofile":{"Name":"nofile","Soft":1048576,"Hard":1048576}}}'
  if [[ ! -f /etc/docker/daemon.json ]] || ! jq -e '.["default-ulimits"].nofile.Soft >= 1048576' /etc/docker/daemon.json >/dev/null 2>&1; then
    if [[ -f /etc/docker/daemon.json ]]; then
      jq -s '.[0] * .[1]' /etc/docker/daemon.json <(echo "$want") >/etc/docker/daemon.json.new
      mv /etc/docker/daemon.json.new /etc/docker/daemon.json
    else
      echo "$want" | jq . >/etc/docker/daemon.json
    fi
    systemctl restart docker
  fi
  systemctl enable --now docker >/dev/null
  [[ -n "${SUDO_USER:-}" ]] && usermod -aG docker "$SUDO_USER" || true

  log "Installing kind ${KIND_VERSION}, kubectl ${KUBECTL_VERSION}, helm ${HELM_VERSION}"
  if [[ "$(kind version 2>/dev/null | awk '{print $2}')" != "${KIND_VERSION}" ]]; then
    curl -fsSLo /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
    chmod +x /usr/local/bin/kind
  fi
  if ! kubectl version --client 2>/dev/null | grep -q "${KUBECTL_VERSION}"; then
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x /usr/local/bin/kubectl
  fi
  if ! helm version --short 2>/dev/null | grep -q "${HELM_VERSION}"; then
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp linux-amd64/helm
    install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm && rm -rf /tmp/linux-amd64
  fi

  log "Kernel tuning (sysctl, THP, swap)"
  cat >/etc/sysctl.d/90-redis-flex-kind.conf <<'EOF'
# kind / many containers
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
fs.file-max = 4194304
# Redis
vm.overcommit_memory = 1
vm.swappiness = 0
net.core.somaxconn = 65535
EOF
  sysctl --system >/dev/null
  swapoff -a || true
  sed -i.bak -E '/\sswap\s/ s/^#*/#/' /etc/fstab || true

  # Redis recommends disabling transparent huge pages.
  cat >/etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (Redis)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
EOF
  systemctl daemon-reload
  systemctl enable --now disable-thp.service >/dev/null
}

# ------------------------------------------------------------------------------
# Pick the NVMe device: explicit NVME_DEVICE, an existing $FLEX_FS_LABEL fs, or
# the single unused NVMe disk (no partitions, not mounted, not the root disk).
detect_nvme() {
  if [[ -n "${NVME_DEVICE}" ]]; then echo "${NVME_DEVICE}"; return; fi
  local labeled; labeled=$(blkid -L "${FLEX_FS_LABEL}" 2>/dev/null || true)
  if [[ -n "$labeled" ]]; then echo "$labeled"; return; fi
  local root_disk candidates=()
  root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)
  while read -r name type model; do
    [[ "$type" == "disk" && "$name" == nvme* && "$name" != "$root_disk" ]] || continue
    [[ -z "$(lsblk -no MOUNTPOINT "/dev/$name" | tr -d '[:space:]')" ]] || continue
    (( $(lsblk -no NAME "/dev/$name" | wc -l) == 1 )) || continue   # has partitions
    candidates+=("/dev/$name|$model")
  done < <(lsblk -dno NAME,TYPE,MODEL)
  # Prefer EC2 instance store when present.
  local c
  for c in "${candidates[@]}"; do [[ "$c" == *"Instance Storage"* ]] && { echo "${c%%|*}"; return; }; done
  (( ${#candidates[@]} == 1 )) || die "found ${#candidates[@]} blank/unused NVMe disks (${candidates[*]:-none}). Set FLEX_DIR=<empty dir on your mounted NVMe> to use an existing mount, or NVME_DEVICE=/dev/nvmeXn1 to have a raw disk formatted."
  echo "${candidates[0]%%|*}"
}

# Decide the flash mode and set FLASH_MODE (existing|managed) and FLASH_PATH (the
# host directory handed to Redis Enterprise).
resolve_flash() {
  [[ -n "${FLASH_MODE:-}" ]] && return
  if [[ -n "${FLEX_DIR}" && -n "${NVME_DEVICE}" ]]; then
    die "set FLEX_DIR (existing mount) or NVME_DEVICE (raw disk to format), not both"
  fi
  if [[ -n "${FLEX_DIR}" ]]; then
    FLASH_MODE=existing
    FLASH_PATH="$(realpath -m "${FLEX_DIR}")"
  else
    FLASH_MODE=managed
    FLASH_PATH="${FLEX_MOUNT}/flash"
  fi
  export FLASH_PATH
}

# Nearest existing directory at or above $1 (for inspecting a not-yet-created dir).
existing_ancestor() {
  local d="$1"
  while [[ ! -d "$d" ]]; do d=$(dirname "$d"); done
  echo "$d"
}

# Existing mount: validate, never format.
prepare_existing_dir() {
  log "Flash storage (existing mount) -> ${FLASH_PATH}"
  local probe target src fstype
  probe=$(existing_ancestor "${FLASH_PATH}")
  target=$(findmnt -no TARGET -T "$probe")
  src=$(findmnt -no SOURCE -T "$probe")
  fstype=$(findmnt -no FSTYPE -T "$probe")
  echo "filesystem: ${src} (${fstype}) mounted at ${target}"
  if [[ "$target" == "/" && "${ALLOW_ROOT_FS}" != "1" ]]; then
    die "FLEX_DIR=${FLEX_DIR} is on the root filesystem. Point it at the NVMe mount (e.g. /data/redis-flex), or set ALLOW_ROOT_FS=1 for testing."
  fi
  [[ "$fstype" == ext4 || "$fstype" == xfs ]] || warn "filesystem is ${fstype}; Redis Flex is tested on ext4/xfs"
  [[ "$src" == /dev/nvme* || "$src" == /dev/md* ]] || warn "${src} does not look like a local NVMe device; Flex needs local NVMe/SSD"
  if ! grep -qsE "[[:space:]]${target}[[:space:]]" /etc/fstab && ! systemctl list-units --type=mount --all --no-legend 2>/dev/null | grep -q "${target} "; then
    warn "${target} is not in /etc/fstab; make sure it is mounted at boot before docker starts"
  fi
  mkdir -p "${FLASH_PATH}"
  # Refuse a non-empty directory unless this tool created it (uninstall wipes it).
  if [[ ! -e "${FLASH_PATH}/.redis-flex-kind" ]] && [[ -n "$(ls -A "${FLASH_PATH}")" ]]; then
    die "${FLASH_PATH} is not empty. FLEX_DIR must be an empty directory dedicated to Redis Flex (its contents are deleted on uninstall)."
  fi
  touch "${FLASH_PATH}/.redis-flex-kind"
}

# Managed raw disk: format if blank, mount, persist.
prepare_managed_disk() {
  log "Flash storage (managed disk) -> ${FLEX_MOUNT}"
  mkdir -p "${FLEX_MOUNT}"
  if mountpoint -q "${FLEX_MOUNT}"; then
    echo "already mounted: $(findmnt -no SOURCE "${FLEX_MOUNT}")"
  else
    local dev fstype label mounts
    dev=$(detect_nvme) || exit 1
    [[ -b "$dev" ]] || die "$dev is not a block device"
    # Never format a disk (or any of its partitions) that is mounted, FORCE_FORMAT or not.
    mounts=$(lsblk -nro MOUNTPOINT "$dev" | grep -v '^$' | tr '\n' ' ' || true)
    if [[ -n "$mounts" ]]; then
      die "$dev is mounted at: ${mounts}- use FLEX_DIR=<empty dir on that mount> instead of NVME_DEVICE."
    fi
    fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)
    label=$(blkid -o value -s LABEL "$dev" 2>/dev/null || true)
    echo "device: $dev ($(lsblk -dno SIZE,MODEL "$dev")) fs=${fstype:-none} label=${label:-none}"
    if [[ -z "$fstype" ]] || [[ "${FORCE_FORMAT}" == "1" && "$label" != "${FLEX_FS_LABEL}" ]]; then
      log "Formatting $dev as ext4 (label ${FLEX_FS_LABEL})"
      wipefs -a "$dev" >/dev/null
      # nodiscard: skip the slow whole-device TRIM at mkfs time; lazy init for speed.
      mkfs.ext4 -F -q -L "${FLEX_FS_LABEL}" -m 0 -E nodiscard,lazy_itable_init=1,lazy_journal_init=1 "$dev"
    elif [[ "$label" != "${FLEX_FS_LABEL}" ]]; then
      die "$dev already has a ${fstype} filesystem (label '${label}'). If it is already mounted, use FLEX_DIR=<dir on that mount> instead; to wipe it set FORCE_FORMAT=1."
    fi
    mount -o noatime,nodiscard "LABEL=${FLEX_FS_LABEL}" "${FLEX_MOUNT}"
  fi

  # Persist the mount. nofail: an EC2 stop/start returns a blank instance-store
  # disk; redis-flex-boot.service re-formats it before docker starts.
  if ! grep -q "LABEL=${FLEX_FS_LABEL}" /etc/fstab; then
    echo "LABEL=${FLEX_FS_LABEL} ${FLEX_MOUNT} ext4 noatime,nodiscard,nofail,x-systemd.device-timeout=10s 0 2" >>/etc/fstab
  fi
  mkdir -p "${FLASH_PATH}"
}

# Uninstall: delete everything in the flash dir except our marker. Only touches a
# dir this tool prepared. (Stale shard data after a pod/host restart is cleared
# by the REC's flex-flash-cleanup init container, see manifests/rec.yaml.tpl.)
clean_flash() {
  if [[ "${FLASH_MODE}" == managed || -e "${FLASH_PATH}/.redis-flex-kind" ]]; then
    find "${FLASH_PATH:?}" -mindepth 1 -maxdepth 1 ! -name .redis-flex-kind -exec rm -rf {} + || true
  fi
}

# Boot unit (both modes): runs before docker, so the kind node never starts with
# the flash path unmounted (which would put "flash" data on the root disk).
install_boot_unit() {
  # Keep a copy of the bundle outside the user's checkout for the boot-time unit.
  if [[ "${BUNDLE_DIR}" != /usr/local/share/redis-flex-kind ]]; then
    mkdir -p /usr/local/share/redis-flex-kind
    cp -r "${BUNDLE_DIR}/redis-flex-kind.sh" "${BUNDLE_DIR}/config.env" "${BUNDLE_DIR}/manifests" /usr/local/share/redis-flex-kind/
  fi
  # Replaced by redis-flex-boot.service (older installs).
  if [[ -f /etc/systemd/system/redis-flex-nvme.service ]]; then
    systemctl disable redis-flex-nvme.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/redis-flex-nvme.service
  fi
  local mnt_unit="$1"
  cat >/etc/systemd/system/redis-flex-boot.service <<EOF
[Unit]
Description=Redis Flex: ensure flash storage is mounted before docker starts
After=local-fs.target ${mnt_unit}
Wants=${mnt_unit}
Before=docker.service

[Service]
Type=oneshot
# Mode and paths come from /var/lib/redis-flex-kind/state.env.
ExecStart=/usr/local/share/redis-flex-kind/redis-flex-kind.sh boot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable redis-flex-boot.service >/dev/null
}

step_nvme() {
  resolve_flash
  if [[ "${FLASH_MODE}" == existing ]]; then prepare_existing_dir; else prepare_managed_disk; fi
  mkdir -p "${PERSIST_HOST_DIR}"
  # Start docker (and so the kind node) only after the flash filesystem is
  # mounted; otherwise kind would bind-mount the empty underlying directory and
  # Redis would silently write "flash" data to the root disk. Wants/After (not
  # Requires) so docker still starts if the mount is missing.
  local mnt_unit; mnt_unit=$(systemd-escape --path --suffix=mount "$(findmnt -no TARGET -T "${FLASH_PATH}")")
  install_boot_unit "${mnt_unit}"
  mkdir -p /etc/systemd/system/docker.service.d
  cat >/etc/systemd/system/docker.service.d/10-redis-flex-mount.conf <<EOF
[Unit]
Wants=${mnt_unit} redis-flex-boot.service
After=${mnt_unit} redis-flex-boot.service
EOF
  systemctl daemon-reload
  # Redis Enterprise runs as uid/gid 1001 (redislabs).
  chown 1001:1001 "${FLASH_PATH}"
  chmod 0775 "${FLASH_PATH}"
  save_state
  df -h "${FLASH_PATH}"
}

# Boot-time (redis-flex-boot.service, before docker): make sure the flash
# filesystem is mounted (managed: format a blank disk). Deletes nothing.
step_boot() {
  FORCE_FORMAT=0
  resolve_flash
  if [[ "${FLASH_MODE}" == managed ]]; then
    prepare_managed_disk
  else
    local target; target=$(findmnt -no TARGET -T "$(existing_ancestor "${FLASH_PATH}")")
    if [[ "$target" == "/" && "${ALLOW_ROOT_FS}" != "1" ]]; then
      die "${FLASH_PATH} resolves to the root filesystem - is the NVMe mount missing? Not cleaning anything."
    fi
    mkdir -p "${FLASH_PATH}"
  fi
  chown 1001:1001 "${FLASH_PATH}"
  chmod 0775 "${FLASH_PATH}"
  echo "flash ready: ${FLASH_PATH} ($(df -h --output=avail "${FLASH_PATH}" | tail -1 | tr -d ' ') free)"
}

# ------------------------------------------------------------------------------
compute_sizes() {
  local mem_kib cpus
  mem_kib=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  cpus=$(nproc)
  [[ -n "${REC_CPU}" ]] || REC_CPU=$(( cpus > 8 ? cpus - 4 : cpus - 2 ))
  [[ -n "${REC_MEMORY}" ]] || REC_MEMORY="$(( mem_kib * 85 / 100 / 1024 / 1024 ))Gi"
  resolve_flash
  if [[ "${FLASH_MODE}" == managed ]]; then
    mountpoint -q "${FLEX_MOUNT}" || die "${FLEX_MOUNT} is not mounted; run the nvme step first"
  fi
  local probe; probe=$(existing_ancestor "${FLASH_PATH}")
  # Free space (not size): correct for a dedicated disk and safe on a shared one.
  # Sizes are computed from what is free *excluding* data already in FLASH_PATH, so
  # re-runs after Redis has written flash data produce the same numbers.
  local avail_kib used_kib
  avail_kib=$(df -k --output=avail "$probe" | tail -1)
  used_kib=$(du -sk "${FLASH_PATH}" 2>/dev/null | cut -f1 || true)
  avail_kib=$(( avail_kib + ${used_kib:-0} ))
  [[ -n "${FLASH_DISK_SIZE}" ]] || FLASH_DISK_SIZE="$(( avail_kib * 97 / 100 / 1024 / 1024 ))Gi"
  [[ -n "${DB_MEMORY}" ]] || DB_MEMORY="$(( avail_kib * 79 / 100 / 1024 / 1024 ))GB"
  if [[ -n "${REDIS_LICENSE_FILE}" ]]; then
    [[ -s "${REDIS_LICENSE_FILE}" ]] || die "REDIS_LICENSE_FILE=${REDIS_LICENSE_FILE} not found/empty"
    REC_LICENSE_LINE="  licenseSecretName: ${REC_NAME}-license"
  else
    REC_LICENSE_LINE=""
  fi
  export KIND_CLUSTER_NAME KIND_NODE_IMAGE FLASH_PATH PERSIST_HOST_DIR LISTEN_ADDRESS \
    HOST_DB_PORT HOST_API_PORT HOST_UI_PORT NAMESPACE REC_NAME REC_CPU REC_MEMORY \
    REC_PERSIST_SIZE FLASH_DISK_SIZE FLASH_CLEANUP_IMAGE REC_LICENSE_LINE DB_NAME DB_PORT DB_MEMORY DB_RAM \
    DB_SHARDS DB_PERSISTENCE DB_EVICTION
}

# Sanity-check DB sizes (GB/Gi values) before Redis Enterprise rejects them with the
# less helpful "Cannot allocate nodes for shards". Dies on impossible combos.
check_db_sizes() {
  local total ram node
  total=$(sed -nE 's/^([0-9]+)G[Bi]?$/\1/p' <<<"${DB_MEMORY}")
  ram=$(sed -nE 's/^([0-9]+)G[Bi]?$/\1/p' <<<"${DB_RAM}")
  node=$(sed -nE 's/^([0-9]+)Gi$/\1/p' <<<"${REC_MEMORY}")
  [[ -n "$total" && -n "$ram" ]] || return 0
  (( ram < total )) || die "DB_RAM (${DB_RAM}) must be smaller than DB_MEMORY (${DB_MEMORY}, RAM + flash total). Flash space is too small or DB_MEMORY is too low."
  if [[ -n "$node" ]] && (( ram * 100 > node * 88 )); then
    warn "DB_RAM (${DB_RAM}) is above ~88% of REC memory (${REC_MEMORY}); Redis Enterprise will likely reject it. Lower DB_RAM or raise REC_MEMORY."
  fi
}

step_kind() {
  compute_sizes
  log "kind cluster '${KIND_CLUSTER_NAME}'"
  mkdir -p "$WORK_DIR"
  if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"; then
    echo "already exists"
    kind export kubeconfig --name "${KIND_CLUSTER_NAME}" --kubeconfig "$KUBECONFIG" >/dev/null
  else
    kind create cluster --config "$(render kind-config.yaml)" --kubeconfig "$KUBECONFIG" --wait 5m
  fi
  save_state
  # Convenience: make kubectl work for the invoking user without flags.
  if [[ -n "${SUDO_USER:-}" ]]; then
    local home; home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    install -d -o "$SUDO_USER" -g "$SUDO_USER" "$home/.kube"
    install -m 0600 -o "$SUDO_USER" -g "$SUDO_USER" "$KUBECONFIG" "$home/.kube/config"
  fi
  install -d /root/.kube && install -m 0600 "$KUBECONFIG" /root/.kube/config
  kubectl get nodes -o wide
  echo "open files inside kind node: $(docker exec "${KIND_CLUSTER_NAME}-control-plane" sh -c 'ulimit -n')"
}

# ------------------------------------------------------------------------------
step_operator() {
  compute_sizes
  log "Redis Enterprise operator ${OPERATOR_CHART_VERSION}"
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  helm repo add redis https://helm.redis.io >/dev/null 2>&1 || true
  helm repo update redis >/dev/null
  helm upgrade --install redis-enterprise-operator redis/redis-enterprise-operator \
    --version "${OPERATOR_CHART_VERSION}" --namespace "${NAMESPACE}" --wait --timeout 10m

  log "Flex storage (StorageClass + static local PV, ${FLASH_DISK_SIZE})"
  kubectl apply -f "$(render flex-storage.yaml)"

  if [[ -n "${REDIS_LICENSE_FILE}" ]]; then
    log "License secret ${REC_NAME}-license"
    kubectl -n "${NAMESPACE}" create secret generic "${REC_NAME}-license" \
      --from-file=license="${REDIS_LICENSE_FILE}" --dry-run=client -o yaml | kubectl apply -f -
  fi
}

# ------------------------------------------------------------------------------
rec_state() { kubectl -n "${NAMESPACE}" get rec "${REC_NAME}" -o jsonpath='{.status.state}' 2>/dev/null; }

# REC Running and its StatefulSet fully rolled out (the operator rolls pods itself,
# so `kubectl rollout status` doesn't apply).
rec_settled() {
  [[ "$(kubectl -n "${NAMESPACE}" get rec "${REC_NAME}" -o jsonpath='{.status.state}')" == Running ]] || return 1
  local st; st=$(kubectl -n "${NAMESPACE}" get sts "${REC_NAME}" -o json) || return 1
  jq -e '.status.currentRevision == .status.updateRevision and (.status.readyReplicas // 0) == .spec.replicas' <<<"$st" >/dev/null
}

# Wait for rec_settled. Single-node caveat: on a spec change the operator rolls the
# only pod and waits for the new one to *join* the cluster, which can't happen with
# nodes: 1 (the pod logs "No pod has been labeled as master pod yet"). If the REC
# sits in RunningRollingUpdate with no bootstrapped pod, trigger the operator's
# documented cluster recovery (spec.clusterRecovery: true) once.
wait_rec_settled() {
  local timeout="$1" start=$SECONDS stuck_since="" recovered=0 state
  until rec_settled; do
    (( SECONDS - start > timeout )) && die "timed out after ${timeout}s waiting for REC ${REC_NAME} to be Running"
    state=$(kubectl -n "${NAMESPACE}" get rec "${REC_NAME}" -o jsonpath='{.status.state}' 2>/dev/null || true)
    # The operator gives the pod a 1-year grace period and RE's preStop hook can't
    # demote the only node, so a graceful delete never finishes; force it.
    local del grace requested
    del=$(kubectl -n "${NAMESPACE}" get pod "${REC_NAME}-0" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)
    if [[ -n "$del" ]]; then
      grace=$(kubectl -n "${NAMESPACE}" get pod "${REC_NAME}-0" -o jsonpath='{.spec.terminationGracePeriodSeconds}' 2>/dev/null || echo 0)
      requested=$(( $(date -d "$del" +%s) - grace ))
      if (( $(date +%s) - requested > REC_FORCE_TERMINATE_AFTER_SECONDS )); then
        warn "${REC_NAME}-0 stuck terminating in RE's preStop hook (single node can't be demoted); force-deleting it"
        kubectl -n "${NAMESPACE}" delete pod "${REC_NAME}-0" --grace-period=0 --force >/dev/null 2>&1 || true
      fi
    fi
    if [[ "$state" == RunningRollingUpdate && $recovered == 0 ]] && \
       kubectl -n "${NAMESPACE}" get pod "${REC_NAME}-0" -o jsonpath='{.status.containerStatuses[?(@.name=="redis-enterprise-node")].ready}' 2>/dev/null | grep -q false; then
      stuck_since=${stuck_since:-$SECONDS}
      if (( SECONDS - stuck_since > 180 )); then
        warn "single-node REC can't complete a rolling update by itself; triggering cluster recovery (spec.clusterRecovery=true)"
        kubectl -n "${NAMESPACE}" patch rec "${REC_NAME}" --type merge -p '{"spec":{"clusterRecovery":true}}'
        recovered=1
      fi
    else
      stuck_since=""
    fi
    sleep 10
  done
}

step_rec() {
  compute_sizes
  log "RedisEnterpriseCluster '${REC_NAME}' (cpu=${REC_CPU} mem=${REC_MEMORY} flash=${FLASH_DISK_SIZE})"
  kubectl apply -f "$(render rec.yaml)"
  echo "waiting for REC to be Running (image pull + bootstrap, ~5-10 min)..."
  # Give the operator a moment to notice a spec change before checking state.
  sleep 15
  wait_rec_settled 1800
  kubectl -n "${NAMESPACE}" get rec,pods,pvc
  if [[ -n "${REDIS_LICENSE_FILE}" ]]; then
    sleep 15
    if kubectl -n "${NAMESPACE}" get rec "${REC_NAME}" -o jsonpath='{.status.licenseStatus.features}' | grep -q trial; then
      warn "license was NOT applied (cluster is on the trial license). Operator says:"
      kubectl -n "${NAMESPACE}" logs deploy/redis-enterprise-operator -c redis-enterprise-operator --tail=500 \
        | grep -o 'Failed setting a new license[^"]*' | tail -1 >&2 || true
      warn "the operator names the RE cluster ${REC_NAME}.${NAMESPACE}.svc.cluster.local; the license must be issued for that name. Continuing on the trial license."
    fi
  fi
}

# ------------------------------------------------------------------------------
step_db() {
  compute_sizes
  log "Flex database '${DB_NAME}' (total=${DB_MEMORY}, ram=${DB_RAM}, shards=${DB_SHARDS}, port=${DB_PORT})"
  check_db_sizes
  if ! kubectl apply -f "$(render redb.yaml)"; then
    die "database rejected (see message above). 'Cannot allocate nodes for shards' = not enough RAM or flash: lower DB_MEMORY / DB_RAM."
  fi
  kubectl apply -f "$(render expose.yaml)"
  # Wait until the database really answers on the host port. (The REDB status can
  # be stale right after a cluster recovery, or stuck in "recovery" until
  # recover_databases runs, so it isn't used as the signal.)
  echo "waiting for ${DB_NAME} to answer PING on ${LISTEN_ADDRESS/0.0.0.0/127.0.0.1}:${HOST_DB_PORT}..."
  recover_databases
  wait_for 900 "${DB_NAME} answering PING" db_ready
  kubectl -n "${NAMESPACE}" get redb "${DB_NAME}"
}

# ------------------------------------------------------------------------------
api() {  # api <path>  - call the RE REST API through the host port
  local user pass
  user=$(kubectl -n "${NAMESPACE}" get secret "${REC_NAME}" -o jsonpath='{.data.username}' | base64 -d)
  pass=$(kubectl -n "${NAMESPACE}" get secret "${REC_NAME}" -o jsonpath='{.data.password}' | base64 -d)
  curl -sk -u "${user}:${pass}" "https://${LISTEN_ADDRESS/0.0.0.0/127.0.0.1}:${HOST_API_PORT}$1"
}

# After a single-node cluster *recovery* (as opposed to a re-create) the database
# comes back in RE state "recovery" and the operator won't touch it ("Database
# changes won't be applied due to its state"). Recover it, as the operator's
# cluster-recovery procedure prescribes. With persistence off this restores the
# configuration only (the data is a cache).
recover_databases() {
  local rl=(kubectl -n "${NAMESPACE}" exec "${REC_NAME}-0" -c redis-enterprise-node -- rladmin)
  if "${rl[@]}" recover list 2>/dev/null | grep -qE '^db:[0-9]+'; then
    warn "database(s) in recovery state after cluster recovery; running 'rladmin recover all'"
    "${rl[@]}" recover all 2>&1 | tail -1 || true
  fi
}

db_ready() { recover_databases; db_ping; }

db_ping() {
  docker run --rm --network host redis:8 redis-cli -h "${LISTEN_ADDRESS/0.0.0.0/127.0.0.1}" -p "${HOST_DB_PORT}" \
    -a "$(db_password)" --no-auth-warning PING 2>/dev/null | grep -q PONG
}

db_password() { kubectl -n "${NAMESPACE}" get secret "redb-${DB_NAME}" -o jsonpath='{.data.password}' | base64 -d; }

step_status() {
  compute_sizes
  log "Status"
  kubectl -n "${NAMESPACE}" get rec,redb,pods,pvc,svc
  log "Database (REST API /v1/bdbs)"
  api /v1/bdbs | jq '.[] | {uid, name, status, port, shards_count, bigstore, bigstore_driver,
      memory_size_GB: (.memory_size/1073741824), bigstore_ram_size_GB: (.bigstore_ram_size/1073741824),
      flash_size_GB: ((.memory_size - .bigstore_ram_size)/1073741824), eviction_policy, data_persistence}'
  log "Node flash / RAM (REST API /v1/nodes)"
  api /v1/nodes | jq '.[] | {uid, status, software_version, cores, total_memory_GB: (.total_memory/1073741824),
      bigstore_driver, bigstore_size_GB: ((.bigstore_size // 0)/1073741824), bigstore_free_GB: ((.bigstore_free // 0)/1073741824)}'
  log "License (REST API /v1/license)"
  api /v1/license | jq '{expired, expiration_date, shards_limit, ram_shards_limit, flash_shards_limit, ram_shards_in_use, flash_shards_in_use, features}'
  cat <<EOF

=============================================================================
 Redis Flex database '${DB_NAME}' is listening on ${LISTEN_ADDRESS}:${HOST_DB_PORT}
   password : $(db_password)
   redis-cli: redis-cli -h 127.0.0.1 -p ${HOST_DB_PORT} -a '<password>'
 RE REST API: https://127.0.0.1:${HOST_API_PORT}   RE admin UI: https://127.0.0.1:${HOST_UI_PORT}
   user/pass: kubectl -n ${NAMESPACE} get secret ${REC_NAME} -o jsonpath='{.data.username}' | base64 -d
 From a laptop: ssh -N -L ${HOST_DB_PORT}:127.0.0.1:${HOST_DB_PORT} -L ${HOST_API_PORT}:127.0.0.1:${HOST_API_PORT} -L ${HOST_UI_PORT}:127.0.0.1:${HOST_UI_PORT} <user>@<this-host>
=============================================================================
EOF
}

step_test() {
  compute_sizes
  log "Smoke test via ${LISTEN_ADDRESS}:${HOST_DB_PORT}"
  local pw; pw=$(db_password)
  local host=${LISTEN_ADDRESS/0.0.0.0/127.0.0.1}
  docker run --rm --network host redis:8 sh -c "
    redis-cli -h $host -p ${HOST_DB_PORT} -a '$pw' --no-auth-warning PING &&
    redis-cli -h $host -p ${HOST_DB_PORT} -a '$pw' --no-auth-warning SET redis-flex-kind:hello world &&
    redis-cli -h $host -p ${HOST_DB_PORT} -a '$pw' --no-auth-warning GET redis-flex-kind:hello &&
    redis-cli -h $host -p ${HOST_DB_PORT} -a '$pw' --no-auth-warning INFO server | grep -E 'redis_version|os'"
}

step_recover() {
  compute_sizes
  log "Recovering the REC / databases if needed"
  local state; state=$(kubectl -n "${NAMESPACE}" get rec "${REC_NAME}" -o jsonpath='{.status.state}')
  echo "REC state: ${state}"
  if [[ "$state" != Running ]]; then
    kubectl -n "${NAMESPACE}" patch rec "${REC_NAME}" --type merge -p '{"spec":{"clusterRecovery":true}}'
    wait_rec_settled 1800
  fi
  recover_databases
  wait_for 900 "${DB_NAME} answering PING" db_ready
  echo "${DB_NAME} is answering on ${LISTEN_ADDRESS}:${HOST_DB_PORT}"
}

step_plan() {
  resolve_flash
  log "Plan (no changes made)"
  echo "flash mode : ${FLASH_MODE}"
  if [[ "${FLASH_MODE}" == existing ]]; then
    echo "flash path : ${FLASH_PATH} (existing mount; never formatted)"
  else
    local dev="${NVME_DEVICE:-}"
    mountpoint -q "${FLEX_MOUNT}" && dev="$(findmnt -no SOURCE "${FLEX_MOUNT}") (already mounted)" || dev="${dev:-$(detect_nvme)}"
    echo "flash disk : ${dev} -> ${FLEX_MOUNT} (formatted only if blank)"
    echo "flash path : ${FLASH_PATH}"
  fi
  if [[ "${FLASH_MODE}" == existing ]] || mountpoint -q "${FLEX_MOUNT}"; then
    compute_sizes
    echo "filesystem : $(findmnt -no SOURCE,FSTYPE,TARGET -T "$(existing_ancestor "${FLASH_PATH}")")"
    echo "REC        : cpu=${REC_CPU} memory=${REC_MEMORY} flashDiskSize=${FLASH_DISK_SIZE}"
    echo "database   : ${DB_NAME} total=${DB_MEMORY} ram=${DB_RAM} shards=${DB_SHARDS} port ${LISTEN_ADDRESS}:${HOST_DB_PORT}"
    check_db_sizes
  else
    echo "sizes      : computed once the disk is formatted + mounted (run: nvme, then plan again)"
  fi
}

step_uninstall() {
  resolve_flash
  log "Deleting kind cluster '${KIND_CLUSTER_NAME}' and its data (disk stays formatted + mounted)"
  kind delete cluster --name "${KIND_CLUSTER_NAME}" || true
  # Flash + persistence contents are tied to the deleted RE cluster; clear them so
  # a re-install bootstraps cleanly. Only touch a flash dir this tool prepared.
  rm -rf "${RENDER_DIR}" "${PERSIST_HOST_DIR:?}"/* || true
  clean_flash
}

# ------------------------------------------------------------------------------
main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { sed -n '2,22p' "$0"; exit 1; }
  need_root "$@"
  mkdir -p "$WORK_DIR"
  [[ "$cmd" == boot || "$cmd" == nvme-boot ]] || exec > >(tee -a "$LOG_FILE") 2>&1
  case "$cmd" in
    install)   step_preflight; step_host; step_nvme; step_kind; step_operator; step_rec; step_db; step_status; step_test ;;
    plan)      step_plan ;;
    recover)   step_recover ;;
    preflight) step_preflight ;;
    host)      step_host ;;
    nvme)      step_nvme ;;
    boot|nvme-boot) step_boot ;;
    kind)      step_kind ;;
    operator)  step_operator ;;
    rec)       step_rec ;;
    db)        step_db ;;
    status)    step_status ;;
    test)      step_test ;;
    uninstall) step_uninstall ;;
    *) die "unknown command: $cmd" ;;
  esac
}
main "$@"
