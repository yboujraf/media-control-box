#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/sys_pkg.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/docker.sh"
env_load "grafana"

PKGS=(ca-certificates curl jq gnupg apt-transport-https openssl)

info "GRAFANA plan"
echo "  - Install base pkgs: ${PKGS[*]}"
echo "  - Ensure docker runtime"
echo "  - Create data/config dirs with UID:GID 472:472"
echo "  - Write grafana.ini (http_addr=127.0.0.1, port=${GRAFANA_HTTP_PORT:-3000})"
echo "  - Run ${GRAFANA_DOCKER_IMAGE:-grafana/grafana-oss:latest} on 127.0.0.1:${GRAFANA_HTTP_PORT:-3000}"
