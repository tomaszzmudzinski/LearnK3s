#!/usr/bin/env bash
set -euo pipefail

# Clean up k3d cluster and local registry created by deploy_k3d.sh
# Usage:
#   ./scripts/clean.sh            # deletes default cluster and registry
#   K3D_CLUSTER_NAME=shop2 ./scripts/clean.sh
#   REGISTRY_NAME=registry.localhost REGISTRY_BIND_PORT=5500 ./scripts/clean.sh

K3D_CLUSTER_NAME=${K3D_CLUSTER_NAME:-shop}
REGISTRY_NAME=${REGISTRY_NAME:-registry.localhost}

log() { printf "\033[1;34m==> %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[warn] %s\033[0m\n" "$*"; }

log "Deleting k3d cluster: ${K3D_CLUSTER_NAME}"
if k3d cluster list | grep -q "^${K3D_CLUSTER_NAME}\b"; then
  k3d cluster delete "${K3D_CLUSTER_NAME}"
else
  warn "Cluster ${K3D_CLUSTER_NAME} not found; skipping."
fi

log "Deleting k3d registry: ${REGISTRY_NAME}"
if docker ps -a --format '{{.Names}}' | grep -q "^k3d-${REGISTRY_NAME}$"; then
  if ! k3d registry delete "${REGISTRY_NAME}"; then
    warn "k3d registry delete failed; attempting force removal via docker."
    # Try exact name first
    CID=$(docker ps -a --filter "name=^/k3d-${REGISTRY_NAME}$" -q)
    if [ -n "$CID" ]; then
      docker rm -f "$CID" || true
    fi
    # As a fallback, remove any containers starting with k3d-${REGISTRY_NAME}
    docker ps -a --format '{{.ID}} {{.Names}}' | awk -v n="k3d-${REGISTRY_NAME}" '$2 ~ "^"n {print $1}' | xargs -r docker rm -f || true
  fi
else
  warn "Registry ${REGISTRY_NAME} not found; skipping."
fi

log "Done."
