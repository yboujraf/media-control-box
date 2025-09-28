#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
env_load "grafana"

PORT="${GRAFANA_HTTP_PORT:-3000}"

info "Grafana status"
docker ps --filter name=grafana --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

echo
info "Logs (last 60):"
(docker logs --tail 60 grafana 2>&1) || true

echo
info "Local HTTP probe"
curl -I -s "http://127.0.0.1:${PORT}" | sed 's/^/  /' || true
