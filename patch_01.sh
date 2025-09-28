#!/usr/bin/env bash
# patch.sh — migrate mon -> grafana and add nginx proxy service (idempotent)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

log()  { printf "[+] %s\n" "$*"; }
info() { printf "[*] %s\n" "$*"; }
warn() { printf "[!] %s\n" "$*"; }
err()  { printf "[x] %s\n" "$*" >&2; }

ensure_dir() {
  mkdir -p "$1"
}

write_file_if_changed() {
  local dest="$1"; shift
  local tmp; tmp="$(mktemp)"
  cat > "$tmp"
  if [[ ! -f "$dest" ]] || ! cmp -s "$tmp" "$dest"; then
    install -D -m 0644 "$tmp" "$dest"
    echo "updated:$dest"
  else
    echo "unchanged:$dest"
  fi
  rm -f "$tmp"
}

safe_mv() {
  local src="$1" dst="$2"
  if [[ -e "$src" ]]; then
    if [[ -e "$dst" ]]; then
      info "target exists, skipping move: $dst"
    else
      mkdir -p "$(dirname "$dst")"
      mv "$src" "$dst"
      echo "moved:$src -> $dst"
    fi
  fi
}

replace_tokens_in_file() {
  local f="$1"
  shift || true
  [[ -f "$f" ]] || return 0
  # expects pairs OLD=NEW
  local sedexpr=()
  for kv in "$@"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    sedexpr+=("-e" "s|\b${k}\b|${v}|g")
  done
  local tmp; tmp="$(mktemp)"
  sed "${sedexpr[@]}" "$f" > "$tmp"
  if ! cmp -s "$tmp" "$f"; then
    install -m 0644 "$tmp" "$f"
    echo "updated:$f"
  else
    echo "unchanged:$f"
  fi
  rm -f "$tmp"
}

################################################################################
# 1) Rename mon -> grafana (scripts & env). TURN is untouched.
################################################################################
log "Step 1: rename 'mon' to 'grafana' (idempotent)"

# Move scripts folder if present
safe_mv "scripts/mon" "scripts/grafana"

# Move env files if present
safe_mv "env/mon.env"         "env/grafana.env"
safe_mv "env/mon.local.env"   "env/grafana.local.env"
safe_mv "env/mon.env.example" "env/grafana.env.example"

# If old grafana files don’t exist (fresh), create env examples
ensure_dir "env"

# Create grafana.env.example (placeholders; safe for git)
write_file_if_changed "env/grafana.env.example" <<'EOF'
# =========================
# GRAFANA (service)
# =========================
GRAFANA_ENABLE="true"

# Domain (used by proxy; Grafana itself binds to loopback)
GRAFANA_DOMAIN="grafana.example.com"

# Docker image
GRAFANA_DOCKER_IMAGE="grafana/grafana-oss:latest"

# Ports (host side bind for container 3000)
GRAFANA_HTTP_PORT="3000"

# Data & config (host paths). Created with UID/GID 472.
GRAFANA_DATA_DIR="./var/state/grafana/data"
GRAFANA_LOG_DIR="./var/logs/grafana"
GRAFANA_PROVISIONING_DIR="./var/state/grafana/provisioning"
GRAFANA_CONFIG_DIR="./var/state/grafana/config"

# Admin (only used if you log in with user/pass; token not stored here)
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASS="CHANGEME"
EOF

# If a local env exists already, leave it. Otherwise create a template local (ignored by git).
if [[ ! -f "env/grafana.local.env" ]]; then
  write_file_if_changed "env/grafana.local.env" <<'EOF'
# =========================
# GRAFANA (local secrets) — NOT COMMITTED
# =========================
# Put your real values here. This file should be gitignored.
/# Example:
GRAFANA_ENABLE="true"
GRAFANA_DOMAIN="grafana.by-research.be"
GRAFANA_HTTP_PORT="3000"

GRAFANA_DATA_DIR="./var/state/grafana/data"
GRAFANA_LOG_DIR="./var/logs/grafana"
GRAFANA_PROVISIONING_DIR="./var/state/grafana/provisioning"
GRAFANA_CONFIG_DIR="./var/state/grafana/config"

GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASS="CHANGEME"
EOF
fi

# Token rename inside any migrated env or scripts (best-effort)
for f in $(git ls-files -m -o --exclude-standard 2>/dev/null || true); do
  case "$f" in
    env/grafana.env|env/grafana.local.env|env/grafana.env.example|scripts/grafana/*)
      replace_tokens_in_file "$f" \
        MON_ENABLE=GRAFANA_ENABLE \
        MON_DOMAIN=GRAFANA_DOMAIN \
        MON_HTTP_PORT=GRAFANA_HTTP_PORT \
        MON_DATA_DIR=GRAFANA_DATA_DIR \
        MON_LOG_DIR=GRAFANA_LOG_DIR \
        MON_PROVISIONING_DIR=GRAFANA_PROVISIONING_DIR \
        MON_CONFIG_DIR=GRAFANA_CONFIG_DIR \
        MON_ENABLE_DIRECT_TLS=GRAFANA_ENABLE_DIRECT_TLS \
        MON_TLS_CERT_PATH=GRAFANA_TLS_CERT_PATH \
        MON_TLS_KEY_PATH=GRAFANA_TLS_KEY_PATH
      ;;
  esac
done

################################################################################
# 2) Ensure grafana service scripts exist (plan/apply/status/remove)
################################################################################
log "Step 2: ensure grafana service scripts exist"

ensure_dir "scripts/grafana"

# plan.sh
write_file_if_changed "scripts/grafana/plan.sh" <<'EOF'
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
EOF
chmod +x "scripts/grafana/plan.sh"

# apply.sh
write_file_if_changed "scripts/grafana/apply.sh" <<'EOF'
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
write_file_if_changed "${CONF_DIR}/grafana.ini" <<CFG
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
EOF
chmod +x "scripts/grafana/apply.sh"

# status.sh
write_file_if_changed "scripts/grafana/status.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
env_load "grafana"

PORT="${GRAFANA_HTTP_PORT:-3000}"

info "Grafana status"
docker ps --filter name=grafana --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

echo
info "Logs (last 60):"
(docker logs --tail 60 grafana 2>&1) || true

echo
info "Local HTTP probe"
curl -I -s "http://127.0.0.1:${PORT}" | sed 's/^/  /' || true
EOF
chmod +x "scripts/grafana/status.sh"

# remove.sh
write_file_if_changed "scripts/grafana/remove.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/docker.sh"
env_load "grafana"

KEEP_DATA="${KEEP_DATA:-true}"
DATA_DIR="${GRAFANA_DATA_DIR:-./var/state/grafana/data}"
LOG_DIR="${GRAFANA_LOG_DIR:-./var/logs/grafana}"
PROV_DIR="${GRAFANA_PROVISIONING_DIR:-./var/state/grafana/provisioning}"
CONF_DIR="${GRAFANA_CONFIG_DIR:-./var/state/grafana/config}"

info "Grafana remove — stopping/removing container"
if docker inspect grafana >/dev/null 2>&1; then
  docker rm -f grafana >/dev/null
  echo "updated:container:grafana:removed"
else
  echo "unchanged:container:grafana"
fi

if [[ "${KEEP_DATA}" != "false" ]]; then
  info "Keeping data/config dirs (set KEEP_DATA=false to purge)"
else
  info "Purging data/config dirs"
  rm -rf "$DATA_DIR" "$LOG_DIR" "$PROV_DIR" "$CONF_DIR"
fi

info "Done."
EOF
chmod +x "scripts/grafana/remove.sh"

################################################################################
# 3) Add nginx reverse proxy service (proxy)
################################################################################
log "Step 3: add nginx proxy service (idempotent)"

ensure_dir "scripts/proxy"
ensure_dir "scripts/proxy/templates"
ensure_dir "env"

# env examples
write_file_if_changed "env/proxy.env.example" <<'EOF'
# =========================
# NGINX PROXY (dockerized)
# =========================
PROXY_ENABLE="true"
PROXY_DOCKER_IMAGE="nginx:stable-alpine"

# Published ports
PROXY_HTTP_PORT="80"
PROXY_HTTPS_PORT="443"

# Config & logs (host)
PROXY_CONF_DIR="./var/state/proxy/nginx"
PROXY_LOG_DIR="./var/logs/proxy"

# Certs path (we reuse system LE via snap certbot): mounted read-only to nginx
PROXY_LETSENCRYPT_DIR="/etc/letsencrypt"

# Per-app toggles
PROXY_GRAFANA_ENABLE="true"

# App domains (used by vhosts)
GRAFANA_DOMAIN="grafana.example.com"
EOF

if [[ ! -f "env/proxy.local.env" ]]; then
  write_file_if_changed "env/proxy.local.env" <<'EOF'
# =========================
# NGINX PROXY (local secrets) — NOT COMMITTED
# =========================
PROXY_ENABLE="true"
PROXY_DOCKER_IMAGE="nginx:stable-alpine"
PROXY_HTTP_PORT="80"
PROXY_HTTPS_PORT="443"

PROXY_CONF_DIR="./var/state/proxy/nginx"
PROXY_LOG_DIR="./var/logs/proxy"

# Use system certs (Let’s Encrypt) in /etc/letsencrypt
PROXY_LETSENCRYPT_DIR="/etc/letsencrypt"

# Per-app toggles
PROXY_GRAFANA_ENABLE="true"

# App domains
GRAFANA_DOMAIN="grafana.by-research.be"
EOF
fi

# Templates: nginx.conf
write_file_if_changed "scripts/proxy/templates/nginx.conf" <<'EOF'
user  nginx;
worker_processes auto;

error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

events { worker_connections 1024; }

http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;

  log_format  main  '$remote_addr - $host [$time_local] "$request" $status $body_bytes_sent '
                    '"$http_referer" "$http_user_agent" '
                    'rt=$request_time ua="$upstream_addr" us="$upstream_status" ut="$upstream_response_time"';

  access_log  /var/log/nginx/access.log  main;

  sendfile        on;
  tcp_nopush      on;
  tcp_nodelay     on;
  keepalive_timeout  65;

  # Gzip — included once to avoid duplicates
  gzip on;
  gzip_vary on;
  gzip_proxied any;
  gzip_comp_level 5;
  gzip_types text/plain text/css application/json application/javascript application/xml+rss application/xml text/javascript;

  include /etc/nginx/conf.d/*.conf;
}
EOF

# Templates: grafana vhost (redirect + TLS upstream to 127.0.0.1:3000)
write_file_if_changed "scripts/proxy/templates/grafana.conf.tpl" <<'EOF'
# HTTP redirect to HTTPS
server {
  listen 80;
  listen [::]:80;
  server_name __GRAFANA_DOMAIN__;

  return 301 https://$host$request_uri;
}

# HTTPS vhost
server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name __GRAFANA_DOMAIN__;

  ssl_certificate     /etc/letsencrypt/live/__GRAFANA_DOMAIN__/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/__GRAFANA_DOMAIN__/privkey.pem;

  # Security headers (basic)
  add_header X-Frame-Options DENY always;
  add_header X-Content-Type-Options nosniff always;
  add_header X-XSS-Protection "1; mode=block" always;

  # Proxy to local grafana
  location / {
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_pass http://127.0.0.1:__GRAFANA_PORT__;
    proxy_read_timeout  60s;
    proxy_send_timeout  60s;
  }
}
EOF

# proxy/plan.sh
write_file_if_changed "scripts/proxy/plan.sh" <<'EOF'
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
EOF
chmod +x "scripts/proxy/plan.sh"

# proxy/apply.sh
write_file_if_changed "scripts/proxy/apply.sh" <<'EOF'
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
write_file_if_changed "${CONF_DIR}/nginx.conf" < "${BASE_TPL}"

# 4) vhost: grafana (if enabled)
if [[ "${PROXY_GRAFANA_ENABLE:-true}" == "true" && -n "${GRAFANA_DOMAIN:-}" ]]; then
  VHOST_TPL="$(cd "$(dirname "$0")/.." && pwd)/templates/grafana.conf.tpl"
  VHOST_OUT="${CONF_DIR}/conf.d/grafana.conf"
  PORT="${GRAFANA_HTTP_PORT:-3000}"
  # render
  sed -e "s|__GRAFANA_DOMAIN__|${GRAFANA_DOMAIN}|g" \
      -e "s|__GRAFANA_PORT__|${PORT}|g" \
      "${VHOST_TPL}" | write_file_if_changed "${VHOST_OUT}" >/dev/null
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
EOF
chmod +x "scripts/proxy/apply.sh"

# proxy/status.sh
write_file_if_changed "scripts/proxy/status.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
env_load "proxy"
env_load "grafana"

info "Proxy status"
docker ps --filter name=nginx --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

echo
info "Loaded vhosts (conf.d)"
ls -1 "${PROXY_CONF_DIR:-./var/state/proxy/nginx}/conf.d" 2>/dev/null || true

if [[ -n "${GRAFANA_DOMAIN:-}" ]]; then
  echo
  info "Probe https://${GRAFANA_DOMAIN} (HEAD)"
  curl -I -s "https://${GRAFANA_DOMAIN}" | sed 's/^/  /' || true
fi
EOF
chmod +x "scripts/proxy/status.sh"

# proxy/remove.sh
write_file_if_changed "scripts/proxy/remove.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
env_load "proxy"

info "Proxy remove — stopping/removing nginx container"
if docker inspect nginx >/dev/null 2>&1; then
  docker rm -f nginx >/dev/null
  echo "updated:container:nginx:removed"
else
  echo "unchanged:container:nginx"
fi

info "Keeping config & logs (set PROXY_PURGE=true and remove manually if desired)."
EOF
chmod +x "scripts/proxy/remove.sh"

################################################################################
# 4) Friendly summary
################################################################################
log "Patch complete."

cat <<'NEXT'

Next steps (nothing auto-runs; you trigger as you like):

# GRAFANA (renamed from mon)
  scripts/grafana/plan.sh
  scripts/grafana/apply.sh
  scripts/grafana/status.sh
  scripts/grafana/remove.sh

# PROXY (nginx)
  scripts/proxy/plan.sh
  scripts/proxy/apply.sh
  scripts/proxy/status.sh
  scripts/proxy/remove.sh

Config:
  - Edit env/grafana.local.env (your domain/ports/paths).
  - Edit env/proxy.local.env   (enable grafana vhost + domain).
  - Grafana stays bound to 127.0.0.1:<GRAFANA_HTTP_PORT>; only nginx exposes 80/443.

TURN:
  - Not touched by this patch. Your TURN service remains as-is.

TLS:
  - The proxy mounts /etc/letsencrypt:ro. Ensure your certs exist for GRAFANA_DOMAIN.
  - If you want me to wire CF DNS-01 issuance into proxy/apply later, say the word.

Idempotency:
  - All scripts follow the same style as TURN (plan/apply/status/remove).
  - Running apply repeatedly won’t clobber data or reopen Grafana to the public.

NEXT


