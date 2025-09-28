#!/usr/bin/env bash
set -euo pipefail
SERVICE_NAME="docker"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/sys_pkg.sh"

env_load "$SERVICE_NAME"
log_file="$(today_log_path "$SERVICE_NAME")"; logln(){ printf "%s\n" "$*" | tee -a "$log_file"; }

logln "PLAN: Docker runtime"
if command -v docker >/dev/null 2>&1; then
  info "docker present: $(docker --version 2>/dev/null | awk '{print $3}')"
else
  info "docker not installed; would install 'docker.io' via apt and enable service"
fi
