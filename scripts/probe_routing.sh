#!/usr/bin/env bash
set -euo pipefail

# Probe ingress routing and show which node/pod served each request.
# Compatible with macOS default bash (no associative arrays).
# Usage: ./probe_routing.sh [times]

TIMES=${1:-10}
K3D_CLUSTER_NAME=${K3D_CLUSTER_NAME:-shop}

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

HOST_HTTP_PORT=${HOST_HTTP_PORT:-$(detect_lb_port)}

if [ "$HOST_HTTP_PORT" != "80" ]; then
  BASE_URL="http://api.127.0.0.1.nip.io:${HOST_HTTP_PORT}"
else
  BASE_URL="http://api.127.0.0.1.nip.io"
fi

printf "==> Probing %s/whoami %d times\n" "$BASE_URL" "$TIMES"

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

for i in $(seq 1 "$TIMES"); do
  RESP=$(curl -s -D - "$BASE_URL/whoami" -o /dev/stdout)
  HEADERS=$(printf "%s" "$RESP" | sed -n '/^$/q;p')
  BODY=$(printf "%s" "$RESP" | sed -n '1,/^$/d')

  POD=$(printf "%s" "$HEADERS" | awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="x-pod-name"{print $2}' | tr -d '\r')
  NODE=$(printf "%s" "$HEADERS" | awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="x-node-name"{print $2}' | tr -d '\r')

  if [ -z "${POD}" ] || [ -z "${NODE}" ]; then
    echo "[$i] Missing tracing headers; response body:" >&2
    echo "$BODY" >&2
  else
    echo "[$i] node=$NODE pod=$POD"
    echo "$NODE,$POD" >> "$TMPFILE"
  fi
  sleep 0.2
done

printf "\n==> Summary by node\n"
if [ -s "$TMPFILE" ]; then
  cut -d',' -f1 "$TMPFILE" | sort | uniq -c | awk '{printf "  %s: %d\n", $2, $1}'
fi

printf "\n==> Summary by pod\n"
if [ -s "$TMPFILE" ]; then
  cut -d',' -f2 "$TMPFILE" | sort | uniq -c | awk '{printf "  %s: %d\n", $2, $1}'
fi
