#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/sys_pkg.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/docker.sh"

env_load "grafana"

# Defaults
GRAFANA_ENABLE="${GRAFANA_ENABLE:-true}"
GRAFANA_DOMAIN="${GRAFANA_DOMAIN:-localhost}"
GRAFANA_LISTEN_HOST="${GRAFANA_LISTEN_HOST:-127.0.0.1}"
GRAFANA_HTTP_PORT="${GRAFANA_HTTP_PORT:-3000}"
GRAFANA_DOCKER_IMAGE="${GRAFANA_DOCKER_IMAGE:-grafana/grafana-oss:latest}"
GRAFANA_UID="${GRAFANA_UID:-472}"
GRAFANA_GID="${GRAFANA_GID:-472}"
GRAFANA_DATA_DIR="${GRAFANA_DATA_DIR:-./var/state/grafana/data}"
GRAFANA_LOG_DIR="${GRAFANA_LOG_DIR:-./var/state/grafana/logs}"
GRAFANA_PROVISIONING_DIR="${GRAFANA_PROVISIONING_DIR:-./var/state/grafana/provisioning}"
GRAFANA_CONFIG_DIR="${GRAFANA_CONFIG_DIR:-./var/state/grafana/config}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASS="${GRAFANA_ADMIN_PASS:-admin}"
NAME="grafana"

if [[ "$GRAFANA_ENABLE" != "true" ]]; then
  warn "GRAFANA_ENABLE is not true; nothing to do."
  exit 0
fi

info "Install base packages"
ensure_packages ca-certificates curl jq gnupg apt-transport-https openssl

info "Ensure docker runtime"
ensure_docker_runtime

# Ensure dirs and ownership
for d in "$GRAFANA_DATA_DIR" "$GRAFANA_LOG_DIR" "$GRAFANA_PROVISIONING_DIR" "$GRAFANA_CONFIG_DIR"; do
  if is_dry_run; then info "DRY-RUN mkdir -p $d"; else install -d -m 0755 "$d"; fi
  if is_dry_run; then info "DRY-RUN chown ${GRAFANA_UID}:${GRAFANA_GID} $d"; else chown -R "${GRAFANA_UID}:${GRAFANA_GID}" "$d" || true; fi
done

# Required provisioning subdirs to silence Grafana errors
for sd in "datasources" "dashboards" "plugins" "alerting"; do
  p="${GRAFANA_PROVISIONING_DIR}/${sd}"
  if is_dry_run; then info "DRY-RUN mkdir -p $p"; else install -d -m 0755 "$p"; fi
  if is_dry_run; then info "DRY-RUN chown ${GRAFANA_UID}:${GRAFANA_GID} $p"; else chown -R "${GRAFANA_UID}:${GRAFANA_GID}" "$p" || true; fi
done

# Minimal dashboards provider file (so provisioning doesn’t error)
dash_provider="${GRAFANA_PROVISIONING_DIR}/dashboards/provider.yaml"
cat <<YAML | write_if_changed "$dash_provider" >/dev/null
apiVersion: 1
providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: true
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
YAML
chown "${GRAFANA_UID}:${GRAFANA_GID}" "$dash_provider" || true
echo "updated:$dash_provider"

# Optional empty datasources file (you can replace later via API or file)
ds_file="${GRAFANA_PROVISIONING_DIR}/datasources/datasources.yaml"
if [[ ! -f "$ds_file" ]]; then
  cat <<'YAML' | write_if_changed "$ds_file" >/dev/null
apiVersion: 1
datasources: []
YAML
  chown "${GRAFANA_UID}:${GRAFANA_GID}" "$ds_file" || true
  echo "updated:$ds_file"
fi

# grafana.ini from env (container paths)
grafana_ini_path="${GRAFANA_CONFIG_DIR}/grafana.ini"
cat >"${grafana_ini_path}.tmp" <<INI
[server]
protocol = http
http_addr = ${GRAFANA_LISTEN_HOST}
http_port = ${GRAFANA_HTTP_PORT}
domain = ${GRAFANA_DOMAIN}
enforce_domain = false
root_url = %(protocol)s://%(domain)s:%(http_port)s/

[security]
admin_user = ${GRAFANA_ADMIN_USER}
# Note: admin_password is not persisted here for security; set via env or UI.

[paths]
provisioning = /etc/grafana/provisioning
data = /var/lib/grafana
logs = /var/log/grafana

[users]
default_theme = system
allow_sign_up = false

[auth]
disable_login_form = false
signout_redirect_url =
INI
write_if_changed "$grafana_ini_path" < "${grafana_ini_path}.tmp" >/dev/null
rm -f "${grafana_ini_path}.tmp"
chown "${GRAFANA_UID}:${GRAFANA_GID}" "$grafana_ini_path" || true
echo "updated:$grafana_ini_path"

# Container spec
image="$GRAFANA_DOCKER_IMAGE"
ports=(-p "${GRAFANA_LISTEN_HOST}:${GRAFANA_HTTP_PORT}:3000")
mounts=(
  -v "$(readlink -f "$GRAFANA_DATA_DIR"):/var/lib/grafana"
  -v "$(readlink -f "$GRAFANA_LOG_DIR"):/var/log/grafana"
  -v "$(readlink -f "$GRAFANA_PROVISIONING_DIR"):/etc/grafana/provisioning"
  -v "$(readlink -f "$GRAFANA_CONFIG_DIR")/grafana.ini:/etc/grafana/grafana.ini:ro"
)

# Spec hash
spec="$(printf "%s|%s|%s|%s|%s|%s" "$image" "${ports[*]}" "${mounts[*]}" "$GRAFANA_LISTEN_HOST" "$GRAFANA_HTTP_PORT" "$GRAFANA_DOMAIN")"
spec_hash="$(sha_spec "$spec")"

# Run or replace
docker_run_or_replace "grafana" "$NAME" "$image" "$spec_hash" -- \
  "${ports[@]}" \
  "${mounts[@]}"

info "Grafana status"
docker ps --filter name="$NAME" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
