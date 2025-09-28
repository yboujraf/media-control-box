#!/usr/bin/env bash
# remove.sh — MON (Grafana) teardown
set -euo pipefail

SERVICE_NAME="mon"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# libs
. "$ROOT/scripts/lib/core.sh"
. "$ROOT/scripts/lib/docker.sh"        || true
. "$ROOT/scripts/lib/net.sh"           || true

env_load "$SERVICE_NAME"

log_file="$(today_log_path "$SERVICE_NAME")"
logln(){ printf "%s\n" "$*" | tee -a "$log_file"; }

NAME="grafana"                      # container name
STATE_DIR="$ROOT/var/state/mon"     # data/provisioning/config live here
LOG_DIR="$ROOT/var/logs/mon"

# Optional toggles (set via env or .env files)
# CLEAN_STATE=true  -> delete var/state/mon (data, plugins, provisioning, config)
# CLEAN_LOGS=true   -> delete var/logs/mon
CLEAN_STATE="${CLEAN_STATE:-false}"
CLEAN_LOGS="${CLEAN_LOGS:-false}"

remove_container() {
  if docker inspect "$NAME" >/dev/null 2>&1; then
    if is_dry_run; then
      info "DRY-RUN docker rm -f $NAME"
    else
      docker rm -f "$NAME" >/dev/null 2>&1 || true
      echo "updated:container:$NAME:removed"
    fi
  else
    info "container $NAME not present"
  fi
}

remove_dirs() {
  local d
  for d in "$@"; do
    if [[ -d "$d" ]]; then
      if is_dry_run; then
        info "DRY-RUN rm -rf $d"
      else
        rm -rf "$d"
        echo "removed:$d"
      fi
    else
      info "dir not present: $d"
    fi
  done
}

logln "REMOVE: $SERVICE_NAME — stopping/removing container and optional data (DNS/certs left intact)"

# 1) Stop & remove container
remove_container

# 2) No UFW rules to revert (Grafana is bound to 127.0.0.1:3000 in apply.sh).
info "no firewall rules to remove (Grafana bound to localhost)"

# 3) Optional: clean data/provisioning/config (kept by default)
if [[ "$CLEAN_STATE" == "true" ]]; then
  logln "[*] CLEAN_STATE=true — removing Grafana state under $STATE_DIR"
  remove_dirs "$STATE_DIR"
else
  info "keeping state under $STATE_DIR (set CLEAN_STATE=true to purge)"
fi

# 4) Optional: clean logs
if [[ "$CLEAN_LOGS" == "true" ]]; then
  logln "[*] CLEAN_LOGS=true — removing logs under $LOG_DIR"
  remove_dirs "$LOG_DIR"
else
  info "keeping logs under $LOG_DIR (set CLEAN_LOGS=true to purge)"
fi

logln "Done. (DNS and certificates intentionally left intact; nginx-proxy will own TLS.)"
