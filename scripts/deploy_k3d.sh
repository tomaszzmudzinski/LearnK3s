#!/usr/bin/env bash
set -euo pipefail

# End-to-end script to build, publish, and deploy Shop.WebApi onto a local k3d (k3s) cluster.
# It is idempotent and will fix common issues like occupied registry or LB ports.
# Requirements: docker, k3d, kubectl

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API_DIR="$REPO_ROOT/Shop.WebApi"
K8S_DIR="$API_DIR/k8s"

# Configurable parameters
REGISTRY_NAME="registry.localhost"
REGISTRY_BIND_PORT=${REGISTRY_BIND_PORT:-5500}
K3D_CLUSTER_NAME=${K3D_CLUSTER_NAME:-shop}
IMAGE_NAME=${IMAGE_NAME:-webapi}
IMAGE_TAG=${IMAGE_TAG:-0.1.0}
NAMESPACE="webapi-demo"
# Preferred host port to expose the cluster's :80 via the load balancer
HOST_HTTP_PORT=${HOST_HTTP_PORT:-80}
# Number of worker nodes (agents) to simulate multiple VPS app servers
AGENTS=${AGENTS:-2}

# Derived
HOST_REGISTRY_REF="${REGISTRY_NAME}:${REGISTRY_BIND_PORT}/${IMAGE_NAME}:${IMAGE_TAG}"
INCLUSTER_REGISTRY_REF="k3d-${REGISTRY_NAME}:${REGISTRY_BIND_PORT}/${IMAGE_NAME}:${IMAGE_TAG}"
LOCAL_IMAGE_REF="${IMAGE_NAME}:${IMAGE_TAG}"

# Helpers
have_cmd() { command -v "$1" >/dev/null 2>&1; }
log() { printf "\033[1;34m==> %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[warn] %s\033[0m\n" "$*"; }
err() { printf "\033[1;31m[err] %s\033[0m\n" "$*"; }
port_in_use() { lsof -Pi :"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }
find_free_port() { local s=$1 e=$2; for ((p=s; p<=e; p++)); do if ! port_in_use "$p"; then echo "$p"; return 0; fi; done; return 1; }
detect_lb_port() {
  # Try to detect the host port mapped to container port 80 on the server load balancer
  local node="k3d-${K3D_CLUSTER_NAME}-serverlb"
  if docker ps --format '{{.Names}}' | grep -q "^${node}$"; then
    local p
    p=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Ports}}{{if eq $k "80/tcp"}}{{(index $v 0).HostPort}}{{end}}{{end}}' "$node" 2>/dev/null || true)
    if [ -n "$p" ]; then
      echo "$p"
      return 0
    fi
  fi
  # default
  echo "80"
}

# Preflight
for tool in docker k3d kubectl; do
  if ! have_cmd "$tool"; then
    err "Missing dependency: $tool. Please install it and re-run."
    exit 1
  fi
done

log "Using repo root: $REPO_ROOT"

# 1) Ensure registry exists and port is available
CONTAINER_NAME="k3d-${REGISTRY_NAME}"
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  log "Registry container exists: ${CONTAINER_NAME}"
else
  if port_in_use "$REGISTRY_BIND_PORT"; then
    warn "Port ${REGISTRY_BIND_PORT} is busy. Trying to remove stale registry container if any."
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
  if port_in_use "$REGISTRY_BIND_PORT"; then
    NEW_PORT=$(find_free_port 5500 5599 || true)
    if [ -z "${NEW_PORT:-}" ]; then
      err "No free port found in 5500-5599 for registry. Aborting."
      exit 1
    fi
    warn "Switching registry port ${REGISTRY_BIND_PORT} -> ${NEW_PORT}"
    REGISTRY_BIND_PORT="$NEW_PORT"
  fi
  log "Creating k3d registry ${REGISTRY_NAME} on port ${REGISTRY_BIND_PORT}"
  k3d registry create "${REGISTRY_NAME}" --port "${REGISTRY_BIND_PORT}"
fi

# Refresh derived refs if port changed
HOST_REGISTRY_REF="${REGISTRY_NAME}:${REGISTRY_BIND_PORT}/${IMAGE_NAME}:${IMAGE_TAG}"
INCLUSTER_REGISTRY_REF="k3d-${REGISTRY_NAME}:${REGISTRY_BIND_PORT}/${IMAGE_NAME}:${IMAGE_TAG}"

# 2) Ensure cluster exists and is connected to registry
if k3d cluster list | grep -q "^${K3D_CLUSTER_NAME}\b"; then
  log "Cluster exists: ${K3D_CLUSTER_NAME}"
  # Detect the LB host port for health checks
  HOST_HTTP_PORT="$(detect_lb_port)"
  # Ensure desired number of agent nodes
  EXISTING_AGENTS=$(docker ps --format '{{.Names}}' | grep -E "^k3d-${K3D_CLUSTER_NAME}-agent-" | wc -l | tr -d ' ')
  if [ "$EXISTING_AGENTS" -lt "$AGENTS" ]; then
    ADDITIONAL=$((AGENTS - EXISTING_AGENTS))
    warn "Cluster has ${EXISTING_AGENTS} agents; adding ${ADDITIONAL} more to reach ${AGENTS}."
    k3d node create --cluster "${K3D_CLUSTER_NAME}" --role agent --replicas "$ADDITIONAL"
  fi
else
  if port_in_use "$HOST_HTTP_PORT"; then
    warn "Host port ${HOST_HTTP_PORT} is busy. Searching for a free alternative (8080-8099)."
    ALT_PORT=$(find_free_port 8080 8099 || true)
    if [ -z "${ALT_PORT:-}" ]; then
      err "No free host port found for load balancer mapping. Aborting."
      exit 1
    fi
    HOST_HTTP_PORT="$ALT_PORT"
    warn "Using host port ${HOST_HTTP_PORT} for the load balancer."
  fi
  log "Creating k3d cluster: ${K3D_CLUSTER_NAME} (LB ${HOST_HTTP_PORT} -> 80)"
  k3d cluster create "${K3D_CLUSTER_NAME}" \
    --registry-use "k3d-${REGISTRY_NAME}:${REGISTRY_BIND_PORT}" \
    --api-port 6550 \
    --agents "${AGENTS}" \
    -p "${HOST_HTTP_PORT}:80@loadbalancer"
  # After creation, ensure we reflect the actual mapped port (in case k3d adjusted it)
  HOST_HTTP_PORT="$(detect_lb_port)"
fi

# 3) Build and push image to host registry
log "Building image: ${HOST_REGISTRY_REF}"
(
  cd "$API_DIR"
  docker build -t "${HOST_REGISTRY_REF}" .
)

log "Tagging local image as ${LOCAL_IMAGE_REF} for direct import"
docker tag "${HOST_REGISTRY_REF}" "${LOCAL_IMAGE_REF}"

log "Pushing image: ${HOST_REGISTRY_REF}"
docker push "${HOST_REGISTRY_REF}"

log "Importing image into k3d cluster: ${LOCAL_IMAGE_REF}"
k3d image import "${LOCAL_IMAGE_REF}" -c "${K3D_CLUSTER_NAME}"

# 4) Switch context, apply manifests, then patch deployment image to use in-cluster registry reference
K3D_CONTEXT="k3d-${K3D_CLUSTER_NAME}"
log "Switching kubectl context to ${K3D_CONTEXT}"
kubectl config use-context "${K3D_CONTEXT}" >/dev/null

# Ensure Traefik (Ingress controller) runs on the server (control-plane) node
log "Pinning Traefik to the control-plane (server) node"
if kubectl -n kube-system get deploy/traefik >/dev/null 2>&1; then
  kubectl -n kube-system patch deploy/traefik --type=strategic -p '
spec:
  replicas: 1
  template:
    spec:
      nodeSelector:
        node-role.kubernetes.io/control-plane: "true"
      affinity: null
'
  # Wait for traefik to roll onto the control-plane node and show placement
  kubectl -n kube-system rollout status deploy/traefik --timeout=120s || true
  kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik -o wide || true
else
  warn "Traefik deployment not found; skipping controller pin."
fi

log "Applying Kubernetes manifests (kustomize)"
kubectl apply -k "$K8S_DIR" >/dev/null

log "Waiting for Deployment/webapi to be created"
for i in {1..30}; do
  if kubectl -n "$NAMESPACE" get deploy/webapi >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

log "Patching deployment image to local reference ${LOCAL_IMAGE_REF}"
kubectl -n "$NAMESPACE" set image deploy/webapi webapi="${LOCAL_IMAGE_REF}" --record=true

# 5) Wait for rollout and print status
log "Waiting for rollout"
kubectl -n "$NAMESPACE" rollout status deploy/webapi

log "Resources in namespace ${NAMESPACE}"
kubectl -n "$NAMESPACE" get all
kubectl -n "$NAMESPACE" get ingress

# Node distribution summary (pods per node)
log "Node distribution (pods by node)"
kubectl -n "$NAMESPACE" get pods -o=custom-columns=NAME:.metadata.name,NODE:.spec.nodeName --no-headers \
  | awk '{count[$2]++} END {for (n in count) printf "  %s: %d pod(s)\n", n, count[n]}'

# 6) Quick health check
if [ "${HOST_HTTP_PORT}" != "80" ]; then
  HEALTH_URL="http://api.127.0.0.1.nip.io:${HOST_HTTP_PORT}/health"
else
  HEALTH_URL="http://api.127.0.0.1.nip.io/health"
fi
log "Probing: ${HEALTH_URL}"
if command -v curl >/dev/null 2>&1; then
  set +e
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL")
  set -e
  if [ "$HTTP_CODE" = "200" ]; then
    log "Health check OK (200)"
  else
    warn "Health check returned HTTP ${HTTP_CODE}. Try port-forward as fallback:"
    echo "kubectl -n ${NAMESPACE} port-forward svc/webapi 8080:80" >&2
    echo "curl -i http://127.0.0.1:8080/health" >&2
  fi
else
  warn "curl not found; skipping HTTP probe."
fi

log "Done."
