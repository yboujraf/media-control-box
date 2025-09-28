#!/usr/bin/env bash
# scripts/grafana/apply.sh — idempotent Grafana deploy
set -euo pipefail

# libs
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/sys_pkg.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/docker.sh"

SERVICE_NAME="grafana"
log_file="$(today_log_path "$SERVICE_NAME")"
log(){ printf "%s\n" "$*" | tee -a "$log_file"; }

# load env (global + grafana + *.local.env)
env_load "grafana"

# --------------------
# defaults (safe fallbacks)
# --------------------
: "${GRAFANA_ENABLE:=true}"
: "${GRAFANA_DOMAIN:=}"
: "${GRAFANA_DOCKER_IMAGE:=grafana/grafana-oss:latest}"

# container listen (inside container) — keep 0.0.0.0 unless you really need to restrict
: "${GRAFANA_LISTEN_HOST:=0.0.0.0}"
# host publish (outside container) — set to 127.0.0.1 to keep it private behind nginx
: "${GRAFANA_PUBLISH_HOST:=127.0.0.1}"
: "${GRAFANA_HTTP_PORT:=3000}"

: "${GRAFANA_UID:=472}"
: "${GRAFANA_GID:=472}"

# paths
: "${GRAFANA_DATA_DIR:=./var/state/grafana/data}"
: "${GRAFANA_LOG_DIR:=./var/state/grafana/logs}"
: "${GRAFANA_PROVISIONING_DIR:=./var/state/grafana/provisioning}"
: "${GRAFANA_CONFIG_DIR:=./var/state/grafana/config}"

# optional admin (used only if you log in with user/pass; do NOT put real secrets in repo)
: "${GRAFANA_ADMIN_USER:=admin}"
: "${GRAFANA_ADMIN_PASS:=CHANGEME}"

# --------------------
# preflight
# --------------------
if [[ "$GRAFANA_ENABLE" != "true" ]]; then
  warn "GRAFANA_ENABLE is not 'true' — skipping apply."
  exit 0
fi

log "[*] Install base packages"
ensure_packages ca-certificates curl jq gnupg apt-transport-https openssl

log "[*] Ensure docker runtime"
ensure_docker_runtime

# --------------------
# ensure dirs & ownership
# --------------------
for d in "$GRAFANA_DATA_DIR" "$GRAFANA_LOG_DIR" "$GRAFANA_PROVISIONING_DIR" "$GRAFANA_CONFIG_DIR"; do
  if is_dry_run; then
    info "DRY-RUN mkdir -p $d && chown ${GRAFANA_UID}:${GRAFANA_GID}"
  else
    install -d -m 0755 "$d"
    chown -R "${GRAFANA_UID}:${GRAFANA_GID}" "$d"
  fi
done

# make provisioning subfolders so Grafana stops warning
for sd in dashboards datasources alerting plugins; do
  if is_dry_run; then
    info "DRY-RUN mkdir -p ${GRAFANA_PROVISIONING_DIR}/${sd}"
  else
    install -d -m 0755 "${GRAFANA_PROVISIONING_DIR}/${sd}"
    chown -R "${GRAFANA_UID}:${GRAFANA_GID}" "${GRAFANA_PROVISIONING_DIR}/${sd}"
  fi
done

# --------------------
# grafana.ini (minimal, points to our bind + paths)
# --------------------
cfg_path="${GRAFANA_CONFIG_DIR}/grafana.ini"
cfg_content="$(cat <<EOF
[server]
http_addr = ${GRAFANA_LISTEN_HOST}
http_port = 3000
domain = ${GRAFANA_DOMAIN}
root_url = %(protocol)s://%(domain)s:%(http_port)s/

[paths]
data = /var/lib/grafana
logs = /var/log/grafana
plugins = /var/lib/grafana/plugins
provisioning = /etc/grafana/provisioning

[log]
mode = console file

[security]
admin_user = ${GRAFANA_ADMIN_USER}
admin_password = ${GRAFANA_ADMIN_PASS}
EOF
)"
printf "%s\n" "$cfg_content" | write_if_changed "$cfg_path" >/dev/null
# keep ownership
if ! is_dry_run; then chown "${GRAFANA_UID}:${GRAFANA_GID}" "$cfg_path"; fi
echo "updated:${cfg_path}"

# --------------------
# run / replace container
# --------------------
log "[*] Pulling ${GRAFANA_DOCKER_IMAGE}"
docker_pull_if_needed "${GRAFANA_DOCKER_IMAGE}"

# compose a spec hash that changes when config/env changes
spec_fingerprint="$(
  printf "%s|" "${GRAFANA_DOCKER_IMAGE}" "${GRAFANA_HTTP_PORT}" "${GRAFANA_LISTEN_HOST}" "${GRAFANA_PUBLISH_HOST}" "${GRAFANA_UID}" "${GRAFANA_GID}"
  sha_spec "$(cat "$cfg_path" 2>/dev/null || true)"
)"
spec_hash="$(sha_spec "$spec_fingerprint")"

log "[*] Recreating container grafana (if spec changed)"
docker_run_or_replace "grafana" "grafana" "${GRAFANA_DOCKER_IMAGE}" "${spec_hash}" -- \
  -p "${GRAFANA_PUBLISH_HOST}:${GRAFANA_HTTP_PORT}:3000" \
  -e "GF_SERVER_HTTP_ADDR=${GRAFANA_LISTEN_HOST}" \
  -e "GF_SERVER_HTTP_PORT=3000" \
  -e "GF_PATHS_CONFIG=/etc/grafana/grafana.ini" \
  -v "$(realpath -m "$GRAFANA_CONFIG_DIR"):/etc/grafana" \
  -v "$(realpath -m "$GRAFANA_PROVISIONING_DIR"):/etc/grafana/provisioning" \
  -v "$(realpath -m "$GRAFANA_DATA_DIR"):/var/lib/grafana" \
  -v "$(realpath -m "$GRAFANA_LOG_DIR"):/var/log/grafana"

# --------------------
# status
# --------------------
log "[*] Grafana status"
docker ps --filter name=grafana

# quick local probe
if command -v curl >/dev/null 2>&1; then
  echo
  echo "[*] Local HTTP probe"
  curl -sSI "http://127.0.0.1:${GRAFANA_HTTP_PORT}" || true
fi
