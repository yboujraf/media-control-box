#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
env_load "grafana"

NAME="grafana"
info "Grafana status"
docker ps --filter name="$NAME" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"

echo
info "Logs (last 60):"
docker logs --tail 60 "$NAME" 2>&1 || true

# Optional quick probe if bound locally
HOST="${GRAFANA_LISTEN_HOST:-127.0.0.1}"
PORT="${GRAFANA_HTTP_PORT:-3000}"
if command -v curl >/dev/null 2>&1; then
  echo
  info "Local HTTP probe"
  curl -sI "http://${HOST}:${PORT}" | sed -n '1,10p' || true
fi
