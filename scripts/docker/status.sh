#!/usr/bin/env bash
set -euo pipefail
SERVICE_NAME="docker"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"

env_load "$SERVICE_NAME"
log_file="$(today_log_path "$SERVICE_NAME")"; logln(){ printf "%s\n" "$*" | tee -a "$log_file"; }

logln "STATUS: Docker runtime"
if command -v docker >/dev/null 2>&1; then
  info "docker: $(docker --version 2>/dev/null)"
  systemctl is-active --quiet docker && info "service: docker is active" || warn "service: docker NOT active"
  docker info --format 'storage: {{.Driver}}, cgroup: {{.CgroupDriver}}' 2>/dev/null || true
else
  warn "docker not installed"
fi
