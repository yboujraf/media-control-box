#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# patch_03.sh — grafana service
# -----------------------------
# What this does:
# - Creates env/grafana.env.example (placeholders, no secrets)
# - Adds scripts/grafana/{plan.sh,apply.sh,status.sh,remove.sh}
# - Uses existing lib helpers (core.sh, sys_pkg.sh, docker.sh)
# - Idempotent, binds Grafana to 127.0.0.1:${GRAFANA_HTTP_PORT} (default 3000)
# - Creates provisioning dirs to silence "can't read .../provisioning" errors
# - DOES NOT TOUCH TURN FILES
#
# Usage:
#   chmod +x patch_03.sh
#   ./patch_03.sh
#
# Then:
#   DRY_RUN=true scripts/grafana/plan.sh
#   DRY_RUN=true scripts/grafana/apply.sh
#   scripts/grafana/apply.sh && scripts/grafana/status.sh
#
# Access locally:
#   curl -I http://127.0.0.1:3000
#   # or SSH tunnel from your laptop:
#   # ssh -L 3000:127.0.0.1:3000 <vps>

root_dir="$(pwd)"

ensure_dir() { install -d -m 0755 "$1"; }
backup_once() {
  local f="$1"
  [[ -f "$f" && ! -f "$f.bak" ]] && cp -p "$f" "$f.bak" || true
}

# --- Preconditions (libs must exist) ---
need=(
  "scripts/lib/core.sh"
  "scripts/lib/docker.sh"
  "scripts/lib/sys_pkg.sh"
)
for f in "${need[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "[x] Missing required helper: $f" >&2
    exit 1
  fi
done

# --- Ensure grafana/ dirs exist ---
ensure_dir "scripts/grafana"
ensure_dir "env"

# --- env/grafana.env.example (safe placeholders) ---
cat > "env/grafana.env.example" <<'ENV'
# =========================
# GRAFANA SERVICE (example)
# =========================
# Enable/disable service
GRAFANA_ENABLE="true"

# Domain used later by the nginx reverse-proxy (optional here)
GRAFANA_DOMAIN="grafana.example.com"

# Bind host: keep 127.0.0.1 when using nginx in front
GRAFANA_LISTEN_HOST="127.0.0.1"
GRAFANA_HTTP_PORT="3000"

# Image & user/group
GRAFANA_DOCKER_IMAGE="grafana/grafana-oss:latest"
GRAFANA_UID="472"
GRAFANA_GID="472"

# Host paths (will be created with UID:GID above)
GRAFANA_DATA_DIR="./var/state/grafana/data"
GRAFANA_LOG_DIR="./var/state/grafana/logs"
GRAFANA_PROVISIONING_DIR="./var/state/grafana/provisioning"
GRAFANA_CONFIG_DIR="./var/state/grafana/config"

# Admin (use local env for real secrets)
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASS="CHANGEME"
# If you later automate dashboards/datasources via API, keep token ONLY in grafana.local.env
GRAFANA_API_TOKEN="CHANGEME"

# Remove volumes on 'remove.sh' when false -> purges data/config
GRAFANA_KEEP_DATA="true"
ENV
echo "updated:env/grafana.env.example"

# --- scripts/grafana/plan.sh ---
cat > "scripts/grafana/plan.sh" <<'SH'
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
SH
chmod +x "scripts/grafana/plan.sh"
echo "updated:scripts/grafana/plan.sh"

# --- scripts/grafana/apply.sh ---
cat > "scripts/grafana/apply.sh" <<'SH'
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
SH
chmod +x "scripts/grafana/apply.sh"
echo "updated:scripts/grafana/apply.sh"

# --- scripts/grafana/status.sh ---
cat > "scripts/grafana/status.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
env_load "grafana"

NAME="grafana"
info "Grafana status"
docker ps --filter name="$NAME" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"

echo
info "Logs (last 60):"
docker logs --tail 60 "$NAME" 2>&1 || true

# Optional quick probe if bound locally
HOST="${GRAFANA_LISTEN_HOST:-127.0.0.1}"
PORT="${GRAFANA_HTTP_PORT:-3000}"
if command -v curl >/dev/null 2>&1; then
  echo
  info "Local HTTP probe"
  curl -sI "http://${HOST}:${PORT}" | sed -n '1,10p' || true
fi
SH
chmod +x "scripts/grafana/status.sh"
echo "updated:scripts/grafana/status.sh"

# --- scripts/grafana/remove.sh ---
cat > "scripts/grafana/remove.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/docker.sh"
env_load "grafana"

NAME="grafana"
KEEP="${GRAFANA_KEEP_DATA:-true}"

info "grafana remove — stopping/removing container"
if docker inspect "$NAME" >/dev/null 2>&1; then
  if is_dry_run; then info "DRY-RUN docker rm -f $NAME"; else docker rm -f "$NAME" >/dev/null; fi
  echo "updated:container:$NAME:removed"
else
  info "container $NAME not present"
fi

if [[ "$KEEP" != "true" ]]; then
  info "Purging data/config dirs"
  for d in "${GRAFANA_DATA_DIR:-./var/state/grafana/data}" \
           "${GRAFANA_LOG_DIR:-./var/state/grafana/logs}" \
           "${GRAFANA_PROVISIONING_DIR:-./var/state/grafana/provisioning}" \
           "${GRAFANA_CONFIG_DIR:-./var/state/grafana/config}"; do
    if [[ -d "$d" ]]; then
      if is_dry_run; then info "DRY-RUN rm -rf $d"; else rm -rf "$d"; fi
      echo "updated:purged:$d"
    fi
  done
else
  info "Keeping data/config dirs (set GRAFANA_KEEP_DATA=false to purge)"
fi

info "Done."
SH
chmod +x "scripts/grafana/remove.sh"
echo "updated:scripts/grafana/remove.sh"

echo
echo "[+] patch_03 complete."
echo "Next:"
echo "  DRY_RUN=true scripts/grafana/plan.sh"
echo "  DRY_RUN=true scripts/grafana/apply.sh"
echo "  scripts/grafana/apply.sh && scripts/grafana/status.sh"
