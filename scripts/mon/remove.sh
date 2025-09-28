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
