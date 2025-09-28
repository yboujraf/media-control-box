#!/usr/bin/env bash
# net.sh — simple network helpers & UFW helpers
set -euo pipefail
# requires: core.sh

port_listening() {
  local proto="${1:?tcp|udp}"; local port="${2:?}"
  local flag
  case "$proto" in
    tcp) flag="-t" ;;
    udp) flag="-u" ;;
    *) echo "invalid proto: $proto" >&2; return 1 ;;
  esac
  if command -v ss >/dev/null 2>&1; then
    ss -ln $flag | grep -q ":$port"
  else
    netstat -ln $flag | grep -q ":$port"
  fi
}

openssl_cert_info() {
  local domain="${1:?}"; local port="${2:?}"
  echo | openssl s_client -connect "${domain}:${port}" -servername "$domain" 2>/dev/null | \
    openssl x509 -noout -subject -issuer -enddate || true
}

ufw_allow() {
  local rule="${1:?}"  # e.g. "3478,5349/tcp" or "49152:65535/udp"
  command -v ufw >/dev/null 2>&1 || { warn "ufw not installed; skipping $rule"; return 0; }
  if is_dry_run; then info "DRY-RUN ufw allow $rule"; return 0; fi
  ufw allow "$rule" || true
}

ufw_delete() {
  local rule="${1:?}"
  command -v ufw >/dev/null 2>&1 || return 0
  if is_dry_run; then info "DRY-RUN ufw delete allow $rule"; return 0; fi
  ufw delete allow "$rule" || true
}
