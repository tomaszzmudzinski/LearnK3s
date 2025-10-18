#!/usr/bin/env bash
set -euo pipefail

# Simulate taking one agent (VPS) out of service and observe traffic shifting.
# Steps:
# 1) Show current pods per node
# 2) Pick an agent node and cordon+drain it (no new pods; evict existing)
# 3) Probe routing during and after
# 4) Optionally uncordon to restore

NAMESPACE="webapi-demo"
K3D_CLUSTER_NAME=${K3D_CLUSTER_NAME:-shop}
KCTX="k3d-${K3D_CLUSTER_NAME}"
TIMES=${TIMES:-10}

detect_lb_port() {
  local node="k3d-${K3D_CLUSTER_NAME}-serverlb"
  if docker ps --format '{{.Names}}' | grep -q "^${node}$"; then
    local p
    p=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Ports}}{{if eq $k "80/tcp"}}{{(index $v 0).HostPort}}{{end}}{{end}}' "$node" 2>/dev/null || true)
    if [ -n "$p" ]; then
      echo "$p"; return 0
    fi
  fi
  echo "80"
}

kubectl config use-context "$KCTX" >/dev/null

HOST_HTTP_PORT=${HOST_HTTP_PORT:-$(detect_lb_port)}
if [ "$HOST_HTTP_PORT" != "80" ]; then
  BASE_URL="http://api.127.0.0.1.nip.io:${HOST_HTTP_PORT}"
else
  BASE_URL="http://api.127.0.0.1.nip.io"
fi

echo "==> Current pods per node"
kubectl -n "$NAMESPACE" get pods -o=custom-columns=NAME:.metadata.name,NODE:.spec.nodeName --no-headers \
  | awk '{count[$2]++} END {for (n in count) printf "  %s: %d pod(s)\n", n, count[n]}'

# Node selection: allow NODE env or AGENT_INDEX=0/1/2, else pick first agent
if [ -n "${NODE:-}" ]; then
  AGENT_NODE="$NODE"
else
  if [ -n "${AGENT_INDEX:-}" ]; then
    AGENT_NODE="k3d-${K3D_CLUSTER_NAME}-agent-${AGENT_INDEX}"
  else
    AGENT_NODE=$(kubectl get nodes -o name | grep agent | head -n1 | sed 's#node/##')
  fi
fi

if [ -z "${AGENT_NODE}" ]; then
  echo "No agent node found; aborting." >&2
  exit 1
fi

echo "==> Cordon + drain node: ${AGENT_NODE}"
kubectl cordon "$AGENT_NODE"
kubectl drain "$AGENT_NODE" --ignore-daemonsets --delete-emptydir-data --force

# Wait for critical components and app to be Ready after rescheduling
echo "==> Waiting for traefik to be Ready"
kubectl -n kube-system rollout status deploy/traefik --timeout=90s || true
echo "==> Waiting for webapi deployment to be Ready"
kubectl -n "$NAMESPACE" rollout status deploy/webapi --timeout=120s || true

# Probe while traffic should shift to remaining nodes
if [ -x "$(dirname "$0")/probe_routing.sh" ]; then
  HOST_HTTP_PORT="$HOST_HTTP_PORT" "$(dirname "$0")/probe_routing.sh" "$TIMES"
else
  echo "probe_routing.sh not found or not executable" >&2
fi

echo "==> Pods per node after drain"
kubectl -n "$NAMESPACE" get pods -o=custom-columns=NAME:.metadata.name,NODE:.spec.nodeName --no-headers \
  | awk '{count[$2]++} END {for (n in count) printf "  %s: %d pod(s)\n", n, count[n]}'

if [ "${UNCORDON:-1}" = "1" ]; then
  echo "==> Uncordon node: ${AGENT_NODE}"
  kubectl uncordon "$AGENT_NODE"
fi
