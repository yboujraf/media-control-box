#!/usr/bin/env bash
set -euo pipefail
SERVICE_NAME="turn"

. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/net.sh"

env_load "$SERVICE_NAME"
log_file="$(today_log_path "$SERVICE_NAME")"; logln(){ printf "%s\n" "$*" | tee -a "$log_file"; }

logln "STATUS: TURN on ${TURN_DOMAIN:-<unset>}"

# container status
if docker inspect coturn >/dev/null 2>&1; then
  info "container: coturn is present"
  docker ps --filter "name=coturn" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true
else
  warn "container: coturn not found"
fi

# ports
info "listening sockets (3478/5349 expected):"
ss -luntp | awk 'NR==1 || /:3478|:5349/' || true

# TLS
if port_listening tcp 5349 && [[ -n "${TURN_DOMAIN:-}" ]]; then
  info "TLS cert:"
  openssl_cert_info "$TURN_DOMAIN" 5349 || true
fi

# metrics (local)
if [[ "${TURN_PROM_ENABLE:-true}" == "true" ]]; then
  info "Prometheus (local): http://127.0.0.1:${TURN_PROM_PORT:-9641}/metrics"
fi
