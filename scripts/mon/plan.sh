#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/../lib/core.sh"
. "$here/../lib/sys_pkg.sh"
env_load mon

log "MON plan"
echo "  - Install base pkgs: ca-certificates curl jq gnupg apt-transport-https openssl"
echo "  - Ensure docker runtime"
echo "  - Create data/config dirs with UID:GID 472:472"
echo "  - Run grafana/grafana:latest on port ${MON_HTTP_PORT:-3000}"
echo "  - (Optional) DNS & cert steps are deferred to nginx-proxy service"
