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

# New canonical name
ensure_packages() {
  local pkgs=("$@")
  (( ${#pkgs[@]} )) || return 0
  apt_update_once
  if is_dry_run; then info "DRY-RUN install pkgs: ${pkgs[*]}"; return 0; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
}

# Backward-compat aliases (some old scripts may call these)
ensure_pkgs() { ensure_packages "$@"; }
ensure_pkg()  { ensure_packages "$@"; }

# New canonical name
ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    info "docker present: $(docker --version | awk '{print $3}')"
    return 0
  fi
  apt_update_once
  if is_dry_run; then info "DRY-RUN install docker.io"; return 0; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
  systemctl enable --now docker
}

# Backward-compat alias
ensure_docker_runtime() { ensure_docker; }
