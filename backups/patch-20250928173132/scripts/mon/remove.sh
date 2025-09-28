#!/usr/bin/env bash
# Remove Grafana container (keeps data, DNS, certs)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/core.sh"

NAME="grafana"

log "MON remove — stopping/removing container (data/DNS/certs preserved)"
if docker inspect "$NAME" >/dev/null 2>&1; then
  if is_dry_run; then
    info "DRY-RUN docker rm -f $NAME"
  else
    docker rm -f "$NAME" >/dev/null
    echo "updated:container:${NAME}:removed"
  fi
else
  info "Container $NAME not present"
fi

# We intentionally leave:
# - var/mon/grafana/* (data, plugins, provisioning)
# - etc/mon/grafana/grafana.ini
# - Cloudflare DNS records
# - Let's Encrypt certs

log "Done. (Data and credentials left intact.)"
