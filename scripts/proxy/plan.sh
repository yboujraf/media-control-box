#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/docker.sh" || true
env_load "proxy"
env_load "grafana"

info "PROXY plan"
echo "  - Image: ${PROXY_DOCKER_IMAGE:-nginx:stable-alpine}"
echo "  - Ports: ${PROXY_HTTP_PORT:-80}/tcp, ${PROXY_HTTPS_PORT:-443}/tcp"
echo "  - Conf dir: ${PROXY_CONF_DIR:-./var/state/proxy/nginx}"
echo "  - Logs dir: ${PROXY_LOG_DIR:-./var/logs/proxy}"
echo "  - Vhost: grafana -> ${GRAFANA_DOMAIN:-(unset)} (enable=${PROXY_GRAFANA_ENABLE:-true})"
echo "  - Certs: using ${PROXY_LETSENCRYPT_DIR:-/etc/letsencrypt} (mounted ro)"
