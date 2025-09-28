#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
env_load "proxy"
env_load "grafana"

info "Proxy status"
docker ps --filter name=nginx --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

echo
info "Loaded vhosts (conf.d)"
ls -1 "${PROXY_CONF_DIR:-./var/state/proxy/nginx}/conf.d" 2>/dev/null || true

if [[ -n "${GRAFANA_DOMAIN:-}" ]]; then
  echo
  info "Probe https://${GRAFANA_DOMAIN} (HEAD)"
  curl -I -s "https://${GRAFANA_DOMAIN}" | sed 's/^/  /' || true
fi
