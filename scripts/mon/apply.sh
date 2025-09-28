#!/usr/bin/env bash
# Apply Grafana (Monitoring) — idempotent
# Requires libs: core.sh, sys_pkg.sh, docker.sh
set -euo pipefail

# --- locate repo root and libs ---
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/core.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/sys_pkg.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/docker.sh"

# Optional CF DNS & Cert libs (only used if present + env set)
DNS_LIB="$ROOT/scripts/lib/dns_cf.sh"
CERT_LIB="$ROOT/scripts/lib/cert_cf.sh"
[[ -f "$DNS_LIB"  ]] && source "$DNS_LIB"  || true
[[ -f "$CERT_LIB" ]] && source "$CERT_LIB" || true

env_load mon

# ---- config from env (mon.env / global.env) -------------------------------
# Required for container run
: "${MON_DOMAIN:=grafana.local}"             # FQDN for Grafana (public vhost)
: "${MON_HTTP_ADDR:=127.0.0.1}"              # bind inside container
: "${MON_HTTP_PORT:=3000}"                   # internal port
: "${MON_EXPOSE_ADDR:=127.0.0.1}"            # host bind (stay local until nginx-proxy)
: "${MON_EXPOSE_PORT:=3000}"                 # host port

# Optional Cloudflare + cert
: "${CF_ZONE:=}"                              # Cloudflare zone (e.g. example.com)
: "${CF_API_TOKEN:=}"                         # Cloudflare token
: "${CF_PROPAGATION_SECONDS:=30}"             # DNS-01 wait
: "${SYS_ADMIN_EMAIL:=}"                      # Certbot registration email
: "${CERT_ECDSA:=true}"                       # prefer ECDSA
: "${CERT_WILDCARD_PAIR:=false}"              # not used here, but supported by lib

# Optional IPs for DNS upsert (fallback auto-detect if missing)
: "${MON_PUBLIC_IP4:=}"
: "${MON_PUBLIC_IP6:=}"

# Paths (host)
DATA_DIR="$ROOT/var/mon/grafana/data"
PLUGINS_DIR="$ROOT/var/mon/grafana/plugins"
PROV_DIR="$ROOT/var/mon/grafana/provisioning"
CONF_DIR="$ROOT/etc/mon/grafana"
CONF_FILE="$CONF_DIR/grafana.ini"

# Container
IMAGE="grafana/grafana:latest"
NAME="grafana"

# --- helpers ---------------------------------------------------------------
detect_public_ips() {
  [[ -n "$MON_PUBLIC_IP4" ]] || MON_PUBLIC_IP4="$(curl -4 -fsS https://ifconfig.co 2>/dev/null || true)"
  [[ -n "$MON_PUBLIC_IP6" ]] || MON_PUBLIC_IP6="$(curl -6 -fsS https://ifconfig.co 2>/dev/null || true)"
}

ensure_base_dirs() {
  install -d -m 0755 "$ROOT/var/mon/grafana" "$CONF_DIR"
  install -d -m 0755 "$DATA_DIR" "$PLUGINS_DIR" "$PROV_DIR"
  # Grafana runs as uid:gid 472:472 — make data/provisioning owned by it
  if is_dry_run; then
    info "DRY-RUN chown -R 472:472 $DATA_DIR $PLUGINS_DIR $PROV_DIR"
  else
    chown -R 472:472 "$DATA_DIR" "$PLUGINS_DIR" "$PROV_DIR"
    chmod -R u+rwX,go-rwx "$DATA_DIR" "$PLUGINS_DIR" "$PROV_DIR"
  fi

  # Minimal config if missing (readable by container)
  if [[ ! -f "$CONF_FILE" ]]; then
    cat <<'INI' | write_if_changed "$CONF_FILE" 0644 >/dev/null
[server]
# container listens on this address/port
http_addr = 127.0.0.1
http_port = 3000

[security]
# default admin creds (change after first login or set via env)
admin_user = admin
admin_password = admin
INI
    # ensure ownership (root-readable is fine)
    if ! is_dry_run; then chown root:root "$CONF_FILE"; chmod 0644 "$CONF_FILE"; fi
  fi
}

dns_upsert_if_possible() {
  # only if lib loaded and token provided and MON_DOMAIN != default
  if declare -F cf_dns_upsert >/dev/null && [[ -n "$CF_API_TOKEN" && -n "$CF_ZONE" ]]; then
    info "Cloudflare zone resolve attempt"
    cf_zone_id_find "$CF_ZONE" >/dev/null

    detect_public_ips
    if [[ -n "$MON_PUBLIC_IP4" ]]; then
      cf_dns_upsert "$MON_DOMAIN" "A"   "$MON_PUBLIC_IP4" "false"
    else
      warn "No IPv4 detected for DNS upsert"
    fi
    if [[ -n "$MON_PUBLIC_IP6" ]]; then
      cf_dns_upsert "$MON_DOMAIN" "AAAA" "$MON_PUBLIC_IP6" "false"
    else
      info "No IPv6 detected (skip AAAA)"
    fi
  else
    warn "dns_cf.sh not sourced or CF vars not set; skipping DNS upsert for $MON_DOMAIN"
  fi
}

cert_issue_if_possible() {
  if declare -F le_prepare >/dev/null && declare -F le_issue_if_needed >/dev/null && [[ -n "$CF_API_TOKEN" && -n "$SYS_ADMIN_EMAIL" ]]; then
    le_prepare
    le_issue_if_needed "$MON_DOMAIN" "$CF_PROPAGATION_SECONDS"
  else
    warn "cert_cf.sh not sourced or CF_API_TOKEN missing; skipping cert issuance for $MON_DOMAIN"
  fi
}

run_container() {
  docker_pull_if_needed "$IMAGE"

  # docker run options (volumes, ports, env)
  local dr_opts=()
  dr_opts+=( -p "${MON_EXPOSE_ADDR}:${MON_EXPOSE_PORT}:${MON_HTTP_PORT}" )
  dr_opts+=( -v "${CONF_FILE}:/etc/grafana/grafana.ini:ro" )
  dr_opts+=( -v "${DATA_DIR}:/var/lib/grafana" )
  dr_opts+=( -v "${PLUGINS_DIR}:/var/lib/grafana/plugins" )
  dr_opts+=( -v "${PROV_DIR}:/etc/grafana/provisioning" )
  dr_opts+=( -e "GF_SERVER_HTTP_ADDR=${MON_HTTP_ADDR}" )
  dr_opts+=( -e "GF_SERVER_HTTP_PORT=${MON_HTTP_PORT}" )
  dr_opts+=( -e "GF_SECURITY_ALLOW_EMBEDDING=true" )
  dr_opts+=( -e "GF_PATHS_CONFIG=/etc/grafana/grafana.ini" )
  dr_opts+=( -e "GF_PATHS_DATA=/var/lib/grafana" )

  # container command (none; use image default)
  local container_cmd=()

  # spec hash for idempotence
  local spec
  spec="$(sha_spec "$IMAGE|$MON_EXPOSE_ADDR|$MON_EXPOSE_PORT|$MON_HTTP_ADDR|$MON_HTTP_PORT|$CONF_FILE|$DATA_DIR|$PLUGINS_DIR|$PROV_DIR")"

  docker_run_or_replace "mon" "$NAME" "$IMAGE" "$spec" -- "${dr_opts[@]}" -- "${container_cmd[@]}"
}

show_status() {
  info "Grafana status"
  docker ps --filter name="$NAME" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" || true
  # Quick health ping (works when bound to localhost)
  if command -v curl >/dev/null 2>&1; then
    sleep 1
    if curl -fsS "http://${MON_EXPOSE_ADDR}:${MON_EXPOSE_PORT}/api/health" >/dev/null 2>&1; then
      info "Grafana /api/health OK at http://${MON_EXPOSE_ADDR}:${MON_EXPOSE_PORT}"
    else
      warn "Grafana /api/health not responding yet"
    fi
  fi
}

main() {
  log "Install base packages"
  ensure_pkgs ca-certificates curl jq gnupg apt-transport-https openssl

  log "Ensure docker runtime"
  ensure_docker_runtime

  ensure_base_dirs
  dns_upsert_if_possible
  cert_issue_if_possible
  info "Pulling $IMAGE"
  docker_pull_if_needed "$IMAGE"
  run_container
  show_status
  log "MON apply complete."
}

main "$@"
