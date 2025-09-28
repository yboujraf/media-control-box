#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/sys_pkg.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/docker.sh"

env_load "grafana"

info "PLAN (grafana)"
echo "  - Install base pkgs: ca-certificates curl jq gnupg apt-transport-https openssl"
echo "  - Ensure docker runtime"
echo "  - Create data/config/provisioning dirs (UID:GID ${GRAFANA_UID:-472}:${GRAFANA_GID:-472})"
echo "  - Render grafana.ini from env (bind ${GRAFANA_LISTEN_HOST:-127.0.0.1}:${GRAFANA_HTTP_PORT:-3000})"
echo "  - Run ${GRAFANA_DOCKER_IMAGE:-grafana/grafana-oss:latest}"
echo "  - Ports: ${GRAFANA_LISTEN_HOST:-127.0.0.1}:${GRAFANA_HTTP_PORT:-3000} -> container:3000"
echo
info "Suggested next:"
echo "  DRY_RUN=true scripts/grafana/apply.sh"
echo "  scripts/grafana/apply.sh && scripts/grafana/status.sh"
