# Single-node kind cluster for Redis Enterprise + Flex.
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${KIND_CLUSTER_NAME}
nodes:
  - role: control-plane
    image: ${KIND_NODE_IMAGE}
    extraMounts:
      # Flash directory on the host NVMe filesystem -> static local PV for Flex.
      - hostPath: ${FLASH_PATH}
        containerPath: ${FLASH_PATH}
      # Backing dir for kind's default local-path StorageClass (REC persistence).
      - hostPath: ${PERSIST_HOST_DIR}
        containerPath: /var/local-path-provisioner
    # host ${LISTEN_ADDRESS}:<hostPort> -> NodePort services in manifests/expose.yaml.tpl
    extraPortMappings:
      - containerPort: 32000
        hostPort: ${HOST_DB_PORT}
        listenAddress: "${LISTEN_ADDRESS}"
        protocol: TCP
      - containerPort: 30943
        hostPort: ${HOST_API_PORT}
        listenAddress: "${LISTEN_ADDRESS}"
        protocol: TCP
      - containerPort: 30443
        hostPort: ${HOST_UI_PORT}
        listenAddress: "${LISTEN_ADDRESS}"
        protocol: TCP
