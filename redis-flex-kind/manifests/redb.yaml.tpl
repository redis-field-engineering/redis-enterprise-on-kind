apiVersion: app.redislabs.com/v1alpha1
kind: RedisEnterpriseDatabase
metadata:
  name: ${DB_NAME}
  namespace: ${NAMESPACE}
spec:
  redisEnterpriseCluster:
    name: ${REC_NAME}
  redisVersion: "8.2"
  # Redis Flex: memorySize = RAM + flash total; rofRamSize = RAM tier.
  isRof: true
  memorySize: ${DB_MEMORY}
  rofRamSize: ${DB_RAM}
  shardCount: ${DB_SHARDS}
  replication: false
  persistence: ${DB_PERSISTENCE}
  evictionPolicy: ${DB_EVICTION}
  databasePort: ${DB_PORT}
  tlsMode: disabled
