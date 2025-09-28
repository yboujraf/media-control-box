#!/usr/bin/env bash
# apply.sh — MON (Grafana) install/upgrade (localhost-only bind)
set -euo pipefail

SERVICE_NAME="mon"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# libs
. "$ROOT/scripts/lib/core.sh"
. "$ROOT/scripts/lib/sys_pkg.sh"      || true
. "$ROOT/scripts/lib/docker.sh"       || true
. "$ROOT/scripts/lib/dns_cf.sh"       || true  # optional, we skip DNS here
. "$ROOT/scripts/lib/cert_cf.sh"      || true  # optional, nginx will own TLS

env_load "$SERVICE_NAME"

log_file="$(today_log_path "$SERVICE_NAME")"
log(){ printf "[+] %s\n" "$*" | tee -a "$log_file"; }
info(){ printf "[*] %s\n" "$*" | tee -a "$log_file"; }
warn(){ printf "[!] %s\n" "$*" | tee -a "$log_file"; }

# -----------------------------
# Defaults (override in env/mon*.env if desired)
# -----------------------------
GRAFANA_IMAGE="${GRAFANA_IMAGE:-grafana/grafana:latest}"
GRAFANA_NAME="${GRAFANA_NAME:-grafana}"
GRAFANA_HTTP_PORT="${GRAFANA_HTTP_PORT:-3000}"   # container port
GRAFANA_BIND_ADDR="${GRAFANA_BIND_ADDR:-127.0.0.1}"  # host bind (loopback)
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
GRAFANA_PLUGINS="${GRAFANA_PLUGINS:-grafana-pyroscope-app,grafana-exploretraces-app,grafana-metricsdrilldown-app,grafana-lokiexplore-app}"

STATE_DIR="$ROOT/var/state/mon"
DATA_DIR="$STATE_DIR/grafana"           # /var/lib/grafana
PROV_DIR="$STATE_DIR/provisioning"      # /etc/grafana/provisioning
CONF_DIR="$STATE_DIR/config"            # /etc/grafana
CONF_INI="$CONF_DIR/grafana.ini"
LOG_DIR="$ROOT/var/logs/mon"

# run uid/gid (Grafana default 472)
GF_UID="${GF_UID:-472}"
GF_GID="${GF_GID:-472}"

log "Install base packages"
ensure_packages ca-certificates curl jq gnupg apt-transport-https openssl

log "Ensure docker runtime"
ensure_docker_runtime

# DNS/cert are handled later by nginx-proxy; we explicitly *skip* here.
if [[ -z "${CF_API_TOKEN:-}" || -z "${CF_ZONE:-}" || -z "${MON_DOMAIN:-}" ]]; then
  warn "dns_cf/cert_cf skipped (nginx-proxy will own DNS/TLS for ${MON_DOMAIN:-<unset>})"
fi

# Dirs & config
mkdir -p "$DATA_DIR" "$PROV_DIR" "$CONF_DIR" "$LOG_DIR"
if ! is_dry_run; then
  chown -R "$GF_UID:$GF_GID" "$DATA_DIR" "$PROV_DIR" || true
  chmod -R u+rwX,go-rwx "$DATA_DIR" "$PROV_DIR" || true
fi

# Minimal grafana.ini (keep defaults; you can extend later)
write_if_changed "$CONF_INI" <<'INI'
[server]
# Protocol stays http behind nginx, we bind to localhost only
protocol = http
http_port = 3000

[security]
# Harden later if desired
cookie_secure = false
allow_embedding = false

[users]
default_theme = dark
INI

# Build a stable spec hash for idempotency
spec_hash="$(sha_spec \
  "$GRAFANA_IMAGE" \
  "$GRAFANA_NAME" \
  "$GRAFANA_BIND_ADDR:$GRAFANA_HTTP_PORT:$GRAFANA_HTTP_PORT" \
  "$GF_UID:$GF_GID" \
  "$(stat -c '%Y' "$CONF_INI" 2>/dev/null || echo 0)" \
)"

log "Pulling $GRAFANA_IMAGE"
docker_pull_if_needed "$GRAFANA_IMAGE"

log "Recreating container $GRAFANA_NAME"

# IMPORTANT: publish ONLY on 127.0.0.1 (no public exposure)
docker_run_or_replace "mon" "$GRAFANA_NAME" "$GRAFANA_IMAGE" "$spec_hash" -- \
  -p "${GRAFANA_BIND_ADDR}:${GRAFANA_HTTP_PORT}:${GRAFANA_HTTP_PORT}/tcp" \
  -e "GF_SECURITY_ADMIN_USER=$GRAFANA_ADMIN_USER" \
  -e "GF_SECURITY_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD" \
  -e "GF_INSTALL_PLUGINS=$GRAFANA_PLUGINS" \
  -v "$DATA_DIR:/var/lib/grafana" \
  -v "$PROV_DIR:/etc/grafana/provisioning" \
  -v "$CONF_DIR:/etc/grafana" \
  --health-cmd='curl -fsS http://127.0.0.1:3000/api/health || exit 1' \
  --health-start-period=30s \
  --health-interval=15s \
  --health-retries=10 \
  -- \
  grafana server

log "Grafana status"
docker ps --filter "name=$GRAFANA_NAME" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

log "MON apply complete."
