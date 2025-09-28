#!/usr/bin/env bash
set -euo pipefail
SERVICE_NAME="turn"

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT_DIR/scripts/lib/core.sh"
. "$ROOT_DIR/scripts/lib/dns_cf.sh"
. "$ROOT_DIR/scripts/lib/cert_cf.sh"
. "$ROOT_DIR/scripts/lib/sys_pkg.sh"
. "$ROOT_DIR/scripts/lib/docker.sh"
. "$ROOT_DIR/scripts/lib/net.sh"

env_load "$SERVICE_NAME"
log_file="$(today_log_path "$SERVICE_NAME")"; logln(){ printf "%s\n" "$*" | tee -a "$log_file"; }

# ---- validate inputs (no secrets printed) ----
require_vars TURN_DOMAIN TURN_REALM TURN_USER TURN_PASS TURN_MIN_PORT TURN_MAX_PORT
: "${TURN_DOCKER_IMAGE:=coturn/coturn:latest}"

# ---- ensure minimal deps ----
ensure_pkgs ca-certificates curl jq gnupg apt-transport-https openssl
ensure_docker_runtime

# ---- DNS: A/AAAA must be DNS-only (never proxied) ----
if [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ZONE:-}" ]]; then
  cf_init
  cf_upsert "$TURN_DOMAIN" A    "${TURN_PUBLIC_IP4:-}" false
  cf_upsert "$TURN_DOMAIN" AAAA "${TURN_PUBLIC_IP6:-}" false
else
  warn "Cloudflare env not set (CF_API_TOKEN/CF_ZONE); skipping DNS upsert."
fi

# ---- Certificates (DNS-01 via Cloudflare) ----
if [[ "${SKIP_CERTS:-false}" == "true" ]]; then
  info "Skipping certificate issuance (SKIP_CERTS=true)."
else
  if [[ -n "${CF_API_TOKEN:-}" ]]; then
    le_prepare
    le_install_hook "30-coturn-reload" '#!/usr/bin/env bash
docker kill -s HUP coturn 2>/dev/null || docker restart coturn 2>/dev/null || true'
    le_issue "$TURN_DOMAIN" "/etc/letsencrypt/renewal-hooks/deploy/30-coturn-reload.sh"
  else
    warn "CF_API_TOKEN not set; skipping certificate issuance."
  fi
fi

# ---- Copy certs into a container-readable path (RO mount) ----
CERT_SRC="/etc/letsencrypt/live/${TURN_DOMAIN}"
CERT_DST="/etc/coturn/certs"
install -d -m 0755 "$CERT_DST"
if [[ -f "$CERT_SRC/fullchain.pem" && -f "$CERT_SRC/privkey.pem" ]]; then
  <"$CERT_SRC/fullchain.pem" write_if_changed "$CERT_DST/fullchain.pem" 0644
  <"$CERT_SRC/privkey.pem"   write_if_changed "$CERT_DST/privkey.pem"   0644
else
  warn "Cert files not present yet in $CERT_SRC (first run or skipped cert issuance)."
fi

# Enforce readable perms every run (inside container, coturn must read them)
ensure_certs_perms() {
  local certdir="/etc/coturn/certs"
  local key="$certdir/privkey.pem"
  local crt="$certdir/fullchain.pem"
  if [[ -f "$crt" && -f "$key" ]]; then
    chmod 0644 "$crt" "$key" || true
    info "Adjusted cert/key permissions in $certdir"
  fi
}
ensure_certs_perms

# ---- Render minimal, correct coturn config ----
install -d -m 0755 /etc/coturn
CFG="/etc/coturn/turnserver.conf"
{
  echo "# TLS certs"
  echo "cert=/config/certs/fullchain.pem"
  echo "pkey=/config/certs/privkey.pem"
  echo
  echo "# listeners"
  echo "listening-port=3478"
  echo "tls-listening-port=5349"
  echo
  echo "# realm & auth"
  echo "realm=${TURN_REALM}"
  echo "user=${TURN_USER}:${TURN_PASS}"
  echo "lt-cred-mech"
  echo "fingerprint"
  echo
  echo "# relay ports"
  echo "min-port=${TURN_MIN_PORT}"
  echo "max-port=${TURN_MAX_PORT}"
  echo
  # Only set external-ip when behind NAT (i.e., local IP provided).
  # On Contabo/public servers: DO NOT set external-ip at all.
  if [[ -n "${TURN_LOCAL_IP4:-}" && -n "${TURN_PUBLIC_IP4:-}" ]]; then
    echo "external-ip=${TURN_PUBLIC_IP4}/${TURN_LOCAL_IP4}"
  fi
  echo
  # Prometheus (optional)
  if [[ "${TURN_PROM_ENABLE:-true}" == "true" ]]; then
    echo "prometheus"
    echo "prometheus-port=${TURN_PROM_PORT:-9641}"
  fi
} | write_if_changed "$CFG" 0644

# ---- Compute spec hash (image + config + command) ----
cfg_hash="$(sha_spec "$(sha256sum "$CFG" | awk '{print $1}')" "${TURN_PROM_ENABLE:-true}" "${TURN_PROM_PORT:-9641}")"

# Exact container command (hash it so arg changes trigger recreate)
container_cmd="turnserver \
    -c /config/turnserver.conf \
    --simple-log \
    --log-file=/dev/stdout \
    --no-cli"

spec_hash="$(sha_spec "$TURN_DOCKER_IMAGE" "$cfg_hash" "$container_cmd")"

# ---- Run/replace container (host networking; RO config mount) ----
docker_run_or_replace "$SERVICE_NAME" "coturn" "$TURN_DOCKER_IMAGE" "$spec_hash" -- \
  --network host \
  -v /etc/coturn:/config:ro \
  -- \
  $container_cmd

# ---- Firewall rules (idempotent) ----
ufw_allow "3478,5349/tcp" || true
ufw_allow "3478,5349/udp" || true
ufw_allow "${TURN_MIN_PORT}:${TURN_MAX_PORT}/udp" || true

# ---- Report ----
info "Ports (expect 3478 and 5349):"
ss -luntp | awk 'NR==1 || /:3478|:5349/' || true
if port_listening tcp 5349; then
  info "TLS cert info:"
  openssl_cert_info "$TURN_DOMAIN" 5349 || true
else
  warn "TLS 5349 not yet listening. See: docker logs coturn"
fi

logln "APPLY: TURN complete."
