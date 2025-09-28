#!/usr/bin/env bash
set -euo pipefail
SERVICE_NAME="docker"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"

env_load "$SERVICE_NAME"
log_file="$(today_log_path "$SERVICE_NAME")"; logln(){ printf "%s\n" "$*" | tee -a "$log_file"; }

logln "REMOVE: Docker runtime (stop & disable). To purge packages, set PURGE=true."
if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet docker 2>/dev/null; then
    if is_dry_run; then info "DRY-RUN systemctl stop docker"; else systemctl stop docker || true; fi
  fi
  if systemctl is-enabled --quiet docker 2>/dev/null; then
    if is_dry_run; then info "DRY-RUN systemctl disable docker"; else systemctl disable docker || true; fi
  fi
fi

if [[ "${PURGE:-false}" == "true" ]]; then
  if is_dry_run; then
    info "DRY-RUN apt-get remove --purge -y docker.io"
  else
    DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y docker.io || true
  fi
else
  info "Not purging docker.io packages (set PURGE=true to remove packages)."
fi

logln "REMOVE: complete."
