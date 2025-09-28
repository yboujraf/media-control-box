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

# --- env loading (dotenv optional) -----------------------------------------
# Usage: env_load <service>
# Loads env/global.env, env/<service>.env then *.local.env unless NO_DOTENV=true.
# Runtime environment always wins.
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
    set -a; source "$f"; set +a
  done
}

# --- validation ------------------------------------------------------------
require_vars() {
  local missing=0 v
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then err "Missing required env: $v"; missing=1; fi
  done
  (( missing == 0 )) || exit 1
}

require_cmd() {
  local miss=0 c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || { err "Missing command: $c"; miss=1; }; done
  (( miss == 0 )) || exit 1
}

# --- files & hashing -------------------------------------------------------
# Writes stdin to dest only if changed; sets mode (default 0644)
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

# --- logs per service ------------------------------------------------------
# today_log_path <service> -> echoes path and ensures dir
today_log_path() {
  local svc="${1:?service required}"
  local root; root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local p="$root/var/logs/$svc/$(date +%F).log"
  install -d -m 0755 "$(dirname "$p")"
  printf "%s" "$p"
}

# --- state dir per service -------------------------------------------------
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
