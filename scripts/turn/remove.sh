#!/usr/bin/env bash
set -euo pipefail
SERVICE_NAME="turn"

. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/net.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/docker.sh"

env_load "$SERVICE_NAME"
log_file="$(today_log_path "$SERVICE_NAME")"; logln(){ printf "%s\n" "$*" | tee -a "$log_file"; }

logln "REMOVE: TURN — stopping/removing container and firewall rules (certs & DNS preserved)"

# container
if docker inspect coturn >/dev/null 2>&1; then
  if is_dry_run; then info "DRY-RUN docker rm -f coturn"; else docker rm -f coturn >/dev/null 2>&1 || true; fi
  echo "updated:container:coturn:removed"
else
  echo "unchanged:container:coturn:not-present"
fi

# firewall
if [[ -n "${TURN_MIN_PORT:-}" && -n "${TURN_MAX_PORT:-}" ]]; then
  ufw_delete "3478,5349/tcp" || true
  ufw_delete "3478,5349/udp" || true
  ufw_delete "${TURN_MIN_PORT}:${TURN_MAX_PORT}/udp" || true
fi

# keep config and certs by default (safer); manual cleanup if needed
logln "Done. (Certificates and DNS records intentionally left intact.)"
