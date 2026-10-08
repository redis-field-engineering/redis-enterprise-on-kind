apiVersion: app.redislabs.com/v1
kind: RedisEnterpriseCluster
metadata:
  name: ${REC_NAME}
  namespace: ${NAMESPACE}
spec:
  # Single node: the only host is one kind node. (Docs list 3 as the production
  # minimum; 1 is fine for a single-box KV cache with no HA.)
  nodes: 1
  redisEnterpriseNodeResources:
    requests:
      cpu: "${REC_CPU}"
      memory: ${REC_MEMORY}
    limits:
      cpu: "${REC_CPU}"
      memory: ${REC_MEMORY}
  persistentSpec:
    enabled: true
    storageClassName: standard
    volumeSize: ${REC_PERSIST_SIZE}
  redisOnFlashSpec:
    enabled: true
    bigStoreDriver: speedb
    storageClassName: redis-flex-local
    flashDiskSize: ${FLASH_DISK_SIZE}
  # Redis Flex doesn't use flash for durability: after any restart of this pod
  # (crash, eviction, host reboot) the operator recovers the cluster and re-creates
  # the database empty, while the old shards' speedb files stay on the NVMe. Those
  # count against free flash and make the re-create fail with "Cannot allocate
  # nodes for shards". Clear them before Redis Enterprise starts.
  redisEnterpriseAdditionalPodSpecAttributes:
    initContainers:
      - name: flex-flash-cleanup
        image: ${FLASH_CLEANUP_IMAGE}
        command: ["sh", "-c", "rm -rf /opt/flash/bigstore-* && echo 'stale Redis Flex shard data cleared'"]
        securityContext:
          runAsUser: 1001
          runAsGroup: 1001
          allowPrivilegeEscalation: false
        volumeMounts:
          - name: redis-on-flash-storage
            mountPath: /opt/flash
${REC_LICENSE_LINE}
