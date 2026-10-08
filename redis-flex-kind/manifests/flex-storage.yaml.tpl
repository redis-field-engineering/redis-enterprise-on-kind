# Static local PV on the NVMe mount for Redis Flex (no dynamic provisioner needed:
# one node, one disk, one PV). The REC's redisOnFlashSpec.storageClassName points here.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: redis-flex-local
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: redis-flex-nvme
  labels:
    app.kubernetes.io/part-of: redis-flex-kind
spec:
  capacity:
    storage: ${FLASH_DISK_SIZE}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: redis-flex-local
  volumeMode: Filesystem
  local:
    path: ${FLASH_PATH}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: ["${KIND_CLUSTER_NAME}-control-plane"]
