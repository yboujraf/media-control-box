#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/sys_pkg.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/docker.sh"
# optional CF libs if you later want DNS/cert automation here:
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/dns_cf.sh"  || true
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/cert_cf.sh" || true

env_load "proxy"
env_load "grafana"

[[ "${PROXY_ENABLE:-true}" == "true" ]] || { info "PROXY_ENABLE=false; nothing to do"; exit 0; }

IMG="${PROXY_DOCKER_IMAGE:-nginx:stable-alpine}"
HPORT="${PROXY_HTTP_PORT:-80}"
SPort="${PROXY_HTTPS_PORT:-443}"
CONF_DIR="${PROXY_CONF_DIR:-./var/state/proxy/nginx}"
LOG_DIR="${PROXY_LOG_DIR:-./var/logs/proxy}"
LE_DIR="${PROXY_LETSENCRYPT_DIR:-/etc/letsencrypt}"

# 1) base packages & docker
ensure_packages ca-certificates curl jq
ensure_docker_runtime

# 2) dirs
install -d -m 0755 "${CONF_DIR}/conf.d" "${LOG_DIR}"

# 3) write base nginx.conf if missing/changed
BASE_TPL="$(cd "$(dirname "$0")/.." && pwd)/templates/nginx.conf"
write_if_changed "${CONF_DIR}/nginx.conf" < "${BASE_TPL}"

# 4) vhost: grafana (if enabled)
if [[ "${PROXY_GRAFANA_ENABLE:-true}" == "true" && -n "${GRAFANA_DOMAIN:-}" ]]; then
  VHOST_TPL="$(cd "$(dirname "$0")/.." && pwd)/templates/grafana.conf.tpl"
  VHOST_OUT="${CONF_DIR}/conf.d/grafana.conf"
  PORT="${GRAFANA_HTTP_PORT:-3000}"
  # render
  sed -e "s|__GRAFANA_DOMAIN__|${GRAFANA_DOMAIN}|g" \
      -e "s|__GRAFANA_PORT__|${PORT}|g" \
      "${VHOST_TPL}" | write_if_changed "${VHOST_OUT}" >/dev/null
else
  # remove vhost if present
  if [[ -f "${CONF_DIR}/conf.d/grafana.conf" ]]; then
    rm -f "${CONF_DIR}/conf.d/grafana.conf"
    echo "updated:${CONF_DIR}/conf.d/grafana.conf:removed"
  else
    echo "unchanged:${CONF_DIR}/conf.d/grafana.conf"
  fi
fi

# 5) container spec & run
SPEC="$(printf '%s' "${IMG}|${HPORT}|${SPort}|${CONF_DIR}|${LOG_DIR}|${LE_DIR}")"
HASH="$(printf "%s" "$SPEC" | sha256sum | awk '{print $1}')"

docker_run_or_replace "proxy" "nginx" "$IMG" "$HASH" -- \
  -p "${HPORT}:80" -p "${SPort}:443" \
  -v "${CONF_DIR}:/etc/nginx:ro" \
  -v "${LOG_DIR}:/var/log/nginx" \
  -v "${LE_DIR}:/etc/letsencrypt:ro"

# 6) quick reload to pick up any config changes (safe if identical)
docker exec nginx nginx -t >/dev/null 2>&1 && docker exec nginx nginx -s reload >/dev/null 2>&1 || true

info "Proxy status"
docker ps --filter name=nginx --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
