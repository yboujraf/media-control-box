#!/usr/bin/env bash
set -euo pipefail
SERVICE_NAME="docker"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/sys_pkg.sh"

env_load "$SERVICE_NAME"
log_file="$(today_log_path "$SERVICE_NAME")"; logln(){ printf "%s\n" "$*" | tee -a "$log_file"; }

logln "APPLY: Docker runtime (install if missing, enable & start)"
ensure_pkgs ca-certificates gnupg apt-transport-https
ensure_docker_runtime
logln "APPLY: Docker runtime complete."
