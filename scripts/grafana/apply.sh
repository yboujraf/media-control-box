#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/sys_pkg.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/docker.sh"
env_load "grafana"

SERVICE="grafana"
IMG="${GRAFANA_DOCKER_IMAGE:-grafana/grafana-oss:latest}"
PORT="${GRAFANA_HTTP_PORT:-3000}"
DATA_DIR="${GRAFANA_DATA_DIR:-./var/state/grafana/data}"
LOG_DIR="${GRAFANA_LOG_DIR:-./var/logs/grafana}"
PROV_DIR="${GRAFANA_PROVISIONING_DIR:-./var/state/grafana/provisioning}"
CONF_DIR="${GRAFANA_CONFIG_DIR:-./var/state/grafana/config}"

# 1) base packages & docker
info "Install base packages"
ensure_packages ca-certificates curl jq gnupg apt-transport-https openssl

info "Ensure docker runtime"
ensure_docker_runtime

# 2) dirs with UID 472
install -d -m 0755 "$DATA_DIR" "$LOG_DIR" "$PROV_DIR" "$CONF_DIR"
chown -R 472:472 "$DATA_DIR" "$LOG_DIR" "$PROV_DIR" || true

# 3) grafana.ini binds loopback only (reverse proxy terminates TLS)
write_if_changed "${CONF_DIR}/grafana.ini" <<CFG
[server]
http_addr = 127.0.0.1
http_port = ${PORT}
domain = ${GRAFANA_DOMAIN:-localhost}
root_url = %(protocol)s://%(domain)s/
serve_from_sub_path = false

[paths]
data = /var/lib/grafana
logs = /var/log/grafana
plugins = /var/lib/grafana/plugins
provisioning = /etc/grafana/provisioning

[users]
default_theme = system

[auth.anonymous]
enabled = false
CFG

# 4) container spec & run
SPEC="$(printf '%s' \
  "${IMG}|${PORT}|${DATA_DIR}|${LOG_DIR}|${PROV_DIR}|${CONF_DIR}"
)"
HASH="$(printf "%s" "$SPEC" | sha256sum | awk '{print $1}')"

docker_run_or_replace "grafana" "grafana" "$IMG" "$HASH" -- \
  -p "127.0.0.1:${PORT}:3000" \
  -v "${DATA_DIR}:/var/lib/grafana" \
  -v "${LOG_DIR}:/var/log/grafana" \
  -v "${PROV_DIR}:/etc/grafana/provisioning" \
  -v "${CONF_DIR}/grafana.ini:/etc/grafana/grafana.ini:ro"

info "Grafana status"
docker ps --filter name=grafana --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
