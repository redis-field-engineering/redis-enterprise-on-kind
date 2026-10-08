# NodePort services targeting the (single) REC pod. kind maps these node ports to
# ${LISTEN_ADDRESS} on the host (see kind-config.yaml.tpl). The operator's own
# services are ClusterIP only, so these are separate, unmanaged services.
apiVersion: v1
kind: Service
metadata:
  name: ${DB_NAME}-nodeport
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    app: redis-enterprise
    redis.io/cluster: ${REC_NAME}
    redis.io/role: node
  ports:
    - name: redis
      port: ${DB_PORT}
      targetPort: ${DB_PORT}
      nodePort: 32000
---
apiVersion: v1
kind: Service
metadata:
  name: ${REC_NAME}-api-nodeport
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    app: redis-enterprise
    redis.io/cluster: ${REC_NAME}
    redis.io/role: node
  ports:
    - name: api
      port: 9443
      targetPort: 9443
      nodePort: 30943
---
apiVersion: v1
kind: Service
metadata:
  name: ${REC_NAME}-ui-nodeport
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    app: redis-enterprise
    redis.io/cluster: ${REC_NAME}
    redis.io/role: node
  ports:
    - name: ui
      port: 8443
      targetPort: 8443
      nodePort: 30443
