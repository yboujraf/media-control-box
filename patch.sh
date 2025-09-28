#!/usr/bin/env bash
set -euo pipefail

root="$(pwd)"
ts="$(date +%Y%m%d%H%M%S)"
bk="${root}/backups/patch-${ts}"
mkdir -p "$bk"

backup() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local dest="$bk/${f#$root/}"
  mkdir -p "$(dirname "$dest")"
  cp -a "$f" "$dest"
}

write_file() {
  local path="$1"; shift
  backup "$path"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'EOF'
__CONTENT_PLACEHOLDER__
EOF
}

chmod_x() { chmod +x "$1" 2>/dev/null || true; }

# ------------------------------------------------------------------------------
# 1) Update shared libs (non-breaking with TURN)
# ------------------------------------------------------------------------------

# core.sh
write_file scripts/lib/core.sh
sed -i '1,$d' scripts/lib/core.sh
cat > scripts/lib/core.sh <<'SH'
#!/usr/bin/env bash
# core.sh — shared primitives: env loading, logging, idempotent writes, hashing, deps
set -euo pipefail

# --- logging ---------------------------------------------------------------
_log()  { printf "%s\n" "$*"; }
log()   { _log "[+] $*"; }
info()  { printf "[*] %s\n" "$*"; }
warn()  { printf "[!] %s\n" "$*"; }
err()   { printf "[x] %s\n" "$*" >&2; }

# --- dry-run flag ----------------------------------------------------------
is_dry_run() { [[ "${DRY_RUN:-false}" == "true" ]]; }

# --- env loading -----------------------------------------------------------
# env_load <service> — loads global.env, <svc>.env then *.local.env (unless NO_DOTENV=true)
env_load() {
  local svc="${1:-}"
  if [[ "${NO_DOTENV:-false}" == "true" ]]; then
    info "NO_DOTENV=true (skipping env/*.env)"
    return 0
  fi
  local root; root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local files=("$root/env/global.env")
  [[ -n "$svc" ]] && files+=("$root/env/${svc}.env")
  files+=("$root/env/global.local.env")
  [[ -n "$svc" ]] && files+=("$root/env/${svc}.local.env")
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    set -a; . "$f"; set +a
  done
}

# load a single env file if exists
load_env_file() {
  local f="${1:-}"
  [[ -z "$f" || ! -f "$f" ]] && return 0
  set -a; . "$f"; set +a
}

# --- validation ------------------------------------------------------------
require_vars() {
  local missing=0 v
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then err "Missing required env: $v"; missing=1; fi
  done
  (( missing == 0 )) || exit 1
}

require_bools() {
  local v
  for v in "$@"; do
    if [[ -n "${!v-}" && "${!v}" != "true" && "${!v}" != "false" ]]; then
      err "$v must be 'true' or 'false' (got: '${!v}')"
      exit 1
    fi
  done
}

require_cmd() {
  local miss=0 c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || { err "Missing command: $c"; miss=1; }; done
  (( miss == 0 )) || exit 1
}

# --- files & hashing -------------------------------------------------------
write_if_changed() {
  local dest="$1"; local mode="${2:-0644}"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp"
  if [[ ! -f "$dest" ]] || ! cmp -s "$tmp" "$dest"; then
    install -D -m "$mode" "$tmp" "$dest"
    echo "updated:$dest"
  else
    echo "unchanged:$dest"
  fi
  rm -f "$tmp"
}

sha_spec() { printf "%s" "$*" | sha256sum | awk '{print $1}'; }

# --- logs & state ----------------------------------------------------------
today_log_path() {
  local svc="${1:?service required}"
  local root; root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local p="$root/var/logs/$svc/$(date +%F).log"
  install -d -m 0755 "$(dirname "$p")"
  printf "%s" "$p"
}

state_dir() {
  local svc="${1:?service required}"
  local root; root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local d="$root/var/state/$svc"
  install -d -m 0755 "$d"
  printf "%s" "$d"
}

# --- masking helper (for logs) --------------------------------------------
mask() {
  local s="${1:-}"
  [[ -z "$s" ]] && { printf ""; return 0; }
  local n=${#s}
  if (( n <= 8 )); then printf "****"; else printf "****%s" "${s: -4}"; fi
}
SH
chmod_x scripts/lib/core.sh

# sys_pkg.sh
write_file scripts/lib/sys_pkg.sh
sed -i '1,$d' scripts/lib/sys_pkg.sh
cat > scripts/lib/sys_pkg.sh <<'SH'
#!/usr/bin/env bash
# sys_pkg.sh — apt helpers, docker runtime ensure
set -euo pipefail
# requires: core.sh

apt_update_once() {
  local stamp="/var/lib/apt/periodic/.mcb-updated"
  if [[ ! -f "$stamp" ]] || find "$stamp" -mmin +60 >/dev/null 2>&1; then
    is_dry_run && { info "DRY-RUN apt-get update"; return 0; }
    apt-get update -y
    install -D -m 0644 /dev/null "$stamp"
  else
    info "apt cache fresh (skip update)"
  fi
}

ensure_pkgs() {
  local pkgs=("$@")
  (( ${#pkgs[@]} )) || return 0
  apt_update_once
  if is_dry_run; then info "DRY-RUN install pkgs: ${pkgs[*]}"; return 0; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
}

# alias for scripts that call ensure_packages
ensure_packages() { ensure_pkgs "$@"; }

ensure_docker_runtime() {
  if command -v docker >/dev/null 2>&1; then
    info "docker present: $(docker --version | awk '{print $3}')"
    return 0
  fi
  apt_update_once
  if is_dry_run; then info "DRY-RUN install docker.io"; return 0; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
  systemctl enable --now docker
}
SH
chmod_x scripts/lib/sys_pkg.sh

# docker.sh
# Keep your existing semantics; add small helpers used by MON.
write_file scripts/lib/docker.sh
sed -i '1,$d' scripts/lib/docker.sh
cat > scripts/lib/docker.sh <<'SH'
#!/usr/bin/env bash
# docker.sh — run/update containers predictably with spec hash
set -euo pipefail
# requires: core.sh

docker_pull_if_needed() {
  local image="${1:?}"
  if is_dry_run; then info "DRY-RUN docker pull $image"; return 0; fi
  docker pull "$image" >/dev/null || true
}

# docker_run_or_replace <service> <name> <image> <spec_hash> -- <docker-run opts...> -- <container cmd...>
docker_run_or_replace() {
  local svc="${1:?}"; local name="${2:?}"; local image="${3:?}"; local spec_hash="${4:?}"; shift 4
  [[ "$1" == "--" ]] && shift || true

  local docker_opts=()
  local container_cmd=()
  local saw_sep=0
  while (( "$#" )); do
    if [[ "$1" == "--" && $saw_sep -eq 0 ]]; then
      saw_sep=1; shift; continue
    fi
    if [[ $saw_sep -eq 0 ]]; then docker_opts+=("$1"); else container_cmd+=("$1"); fi
    shift
  done

  local sd; sd="$(state_dir "$svc")"
  local hf="$sd/${name}.sha256"
  local prev="$(cat "$hf" 2>/dev/null || true)"

  docker_pull_if_needed "$image"

  if docker inspect "$name" >/dev/null 2>&1; then
    if [[ "$prev" == "$spec_hash" ]]; then
      info "container $name unchanged (spec match)"
      docker start "$name" >/dev/null || true
      return 0
    fi
    info "container $name spec changed; will recreate"
    if ! is_dry_run; then docker rm -f "$name" >/dev/null 2>&1 || true; fi
  fi

  if is_dry_run; then
    info "DRY-RUN docker run $name ($image) with new spec"
    return 0
  fi

  if (( ${#container_cmd[@]} )); then
    docker run -d --name "$name" --restart unless-stopped "${docker_opts[@]}" "$image" "${container_cmd[@]}"
  else
    docker run -d --name "$name" --restart unless-stopped "${docker_opts[@]}" "$image"
  fi
  printf "%s\n" "$spec_hash" > "$hf"
  echo "updated:container:$name"
}

docker_is_healthy() {
  local name="${1:?}"
  [[ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo "unknown")" == "healthy" ]]
}

docker_logs_tail() {
  local name="${1:?}"; local n="${2:-100}"
  docker logs --tail "$n" "$name" 2>&1 || true
}

docker_rm_if_exists() {
  local name="${1:?}"
  if docker inspect "$name" >/dev/null 2>&1; then
    is_dry_run && { info "DRY-RUN docker rm -f $name"; return 0; }
    docker rm -f "$name" >/dev/null 2>&1 || true
    echo "updated:container:${name}:removed"
  fi
}

docker_spec_hash() {
  sha_spec "$@"
}
SH
chmod_x scripts/lib/docker.sh

# Do NOT touch your Cloudflare libs (they already exist & work for TURN)
# scripts/lib/dns_cf.sh and scripts/lib/cert_cf.sh remain as-is.

# ------------------------------------------------------------------------------
# 2) MON (Grafana) scripts
# ------------------------------------------------------------------------------

# env example
write_file env/mon.env.example
sed -i '1,$d' env/mon.env.example
cat > env/mon.env.example <<'EOF'
# =========================
# MONITORING / GRAFANA
# =========================
# Domain (optional if you’ll front with nginx later)
MON_DOMAIN="grafana.example.com"

# Ports (host)
MON_HTTP_PORT="3000"

# Data & config (host paths). These are created with UID/GID 472.
MON_DATA_DIR="./var/state/mon/grafana"
MON_LOG_DIR="./var/logs/mon"
MON_PROVISIONING_DIR="./var/state/mon/provisioning"
MON_CONFIG_DIR="./var/state/mon/config"

# TLS direct (NOT recommended when using nginx). Leave false if proxying.
MON_ENABLE_DIRECT_TLS="false"
MON_TLS_CERT_PATH=""   # e.g., /etc/letsencrypt/live/${MON_DOMAIN}/fullchain.pem
MON_TLS_KEY_PATH=""    # e.g., /etc/letsencrypt/live/${MON_DOMAIN}/privkey.pem
EOF

# plan.sh
write_file scripts/mon/plan.sh
sed -i '1,$d' scripts/mon/plan.sh
cat > scripts/mon/plan.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/../lib/core.sh"
. "$here/../lib/sys_pkg.sh"
env_load mon

log "MON plan"
echo "  - Install base pkgs: ca-certificates curl jq gnupg apt-transport-https openssl"
echo "  - Ensure docker runtime"
echo "  - Create data/config dirs with UID:GID 472:472"
echo "  - Run grafana/grafana:latest on port ${MON_HTTP_PORT:-3000}"
echo "  - (Optional) DNS & cert steps are deferred to nginx-proxy service"
SH
chmod_x scripts/mon/plan.sh

# status.sh
write_file scripts/mon/status.sh
sed -i '1,$d' scripts/mon/status.sh
cat > scripts/mon/status.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/../lib/core.sh"
. "$here/../lib/docker.sh"
env_load mon

log "Grafana status"
docker ps --filter name=grafana --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
echo
info "Logs (last 60):"
docker_logs_tail grafana 60 || true
SH
chmod_x scripts/mon/status.sh

# remove.sh
write_file scripts/mon/remove.sh
sed -i '1,$d' scripts/mon/remove.sh
cat > scripts/mon/remove.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/../lib/core.sh"
. "$here/../lib/docker.sh"
env_load mon

KEEP_DATA="${KEEP_DATA:-true}"

log "MON remove — stopping/removing Grafana container"
docker_rm_if_exists grafana

if [[ "$KEEP_DATA" == "false" ]]; then
  warn "KEEP_DATA=false — purging data/config dirs"
  for d in "${MON_DATA_DIR:-./var/state/mon/grafana}" \
           "${MON_PROVISIONING_DIR:-./var/state/mon/provisioning}" \
           "${MON_CONFIG_DIR:-./var/state/mon/config}"; do
    [[ -z "$d" ]] && continue
    is_dry_run && { info "DRY-RUN rm -rf $d"; continue; }
    rm -rf "$d"
  done
else
  info "Keeping data/config dirs (set KEEP_DATA=false to purge)"
fi

log "Done."
SH
chmod_x scripts/mon/remove.sh

# apply.sh
write_file scripts/mon/apply.sh
sed -i '1,$d' scripts/mon/apply.sh
cat > scripts/mon/apply.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

# shell libs
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/../lib/core.sh"
. "$here/../lib/sys_pkg.sh"
. "$here/../lib/docker.sh"
# DNS/cert libs are optional for MON (usually fronted by nginx)
[[ -f "$here/../lib/dns_cf.sh" ]] && . "$here/../lib/dns_cf.sh" || true
[[ -f "$here/../lib/cert_cf.sh" ]] && . "$here/../lib/cert_cf.sh" || true

env_load mon

# Defaults
MON_HTTP_PORT="${MON_HTTP_PORT:-3000}"
MON_DATA_DIR="${MON_DATA_DIR:-./var/state/mon/grafana}"
MON_LOG_DIR="${MON_LOG_DIR:-./var/logs/mon}"
MON_PROVISIONING_DIR="${MON_PROVISIONING_DIR:-./var/state/mon/provisioning}"
MON_CONFIG_DIR="${MON_CONFIG_DIR:-./var/state/mon/config}"
MON_ENABLE_DIRECT_TLS="${MON_ENABLE_DIRECT_TLS:-false}"
require_bools MON_ENABLE_DIRECT_TLS

log "Install base packages"
ensure_pkgs ca-certificates curl jq gnupg apt-transport-https openssl

log "Ensure docker runtime"
ensure_docker_runtime

# Optional DNS upsert (discouraged here; let nginx-proxy own public DNS)
if [[ -n "${MON_DOMAIN:-}" ]]; then
  if declare -F cf_dns_upsert >/dev/null && [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ZONE:-}" ]]; then
    info "DNS upsert (A/AAAA) for ${MON_DOMAIN}"
    cf_dns_upsert "${MON_DOMAIN}" "A"   "${PUBLIC_IPV4:-}" "false" || true
    [[ -n "${PUBLIC_IPV6:-}" ]] && cf_dns_upsert "${MON_DOMAIN}" "AAAA" "${PUBLIC_IPV6}" "false" || true
  else
    warn "dns_cf.sh not sourced or CF vars not set; skipping DNS upsert for ${MON_DOMAIN}"
  fi
fi

# Optional direct TLS (NOT recommended when using nginx)
if [[ "${MON_ENABLE_DIRECT_TLS}" == "true" ]]; then
  if declare -F le_issue >/dev/null && [[ -n "${CF_API_TOKEN:-}" && -n "${SYS_ADMIN_EMAIL:-}" && -n "${MON_DOMAIN:-}" ]]; then
    info "Direct TLS requested — issuing cert for ${MON_DOMAIN}"
    le_issue "${MON_DOMAIN}" "${CF_PROPAGATION_SECONDS:-30}" || warn "cert issuance failed"
  else
    warn "cert_cf.sh not sourced or CF_API_TOKEN missing; skipping cert issuance for ${MON_DOMAIN}"
  fi
fi

# Ensure host paths & permissions (Grafana requires UID 472)
uid=472; gid=472
for d in "$MON_DATA_DIR" "$MON_LOG_DIR" "$MON_PROVISIONING_DIR" "$MON_CONFIG_DIR"; do
  is_dry_run && { info "DRY-RUN mkdir -p $d"; continue; }
  install -d -m 0755 "$d"
  chown -R "$uid:$gid" "$d" || true
done

# Minimal config file (readable by UID 472)
graf_ini="$MON_CONFIG_DIR/grafana.ini"
write_if_changed "$graf_ini" 0644 <<EOF
[server]
domain = ${MON_DOMAIN:-localhost}
http_port = ${MON_HTTP_PORT}
root_url = %(protocol)s://%(domain)s/
serve_from_sub_path = false
EOF

# Build run spec
image="grafana/grafana:latest"
name="grafana"

run_opts=(
  -p "${MON_HTTP_PORT}:3000"
  -v "${MON_DATA_DIR}:/var/lib/grafana"
  -v "${MON_LOG_DIR}:/var/log/grafana"
  -v "${MON_PROVISIONING_DIR}:/etc/grafana/provisioning"
  -v "${graf_ini}:/etc/grafana/grafana.ini:ro"
  -e "GF_PATHS_CONFIG=/etc/grafana/grafana.ini"
  -e "GF_SERVER_ROOT_URL=%(protocol)s://%(domain)s/"
  -e "GF_SERVER_DOMAIN=${MON_DOMAIN:-localhost}"
  -u "472:472"
)

# Healthcheck baked in by Grafana; relying on restart policy.
spec_hash="$(docker_spec_hash "${image}" "${name}" "${run_opts[@]}")"

log "Pulling ${image}"
docker_pull_if_needed "${image}"

log "Recreating container ${name}"
docker_run_or_replace "mon" "${name}" "${image}" "${spec_hash}" -- "${run_opts[@]}"

log "Grafana status"
docker ps --filter name="${name}" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"

log "MON apply complete."
SH
chmod_x scripts/mon/apply.sh

# ------------------------------------------------------------------------------
# 3) Gentle nudge to keep TURN intact (no changes), ensure dirs exist
# ------------------------------------------------------------------------------
mkdir -p var/logs/turn var/state/turn var/logs/mon var/state/mon

# ------------------------------------------------------------------------------
# 4) Finish
# ------------------------------------------------------------------------------
echo
echo "[OK] Patch applied. Backup of replaced files: $bk"
echo "Next:"
echo "  DRY_RUN=true scripts/mon/plan.sh"
echo "  DRY_RUN=true scripts/mon/apply.sh"
echo "  scripts/mon/apply.sh && scripts/mon/status.sh"
