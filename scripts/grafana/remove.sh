#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/docker.sh"
env_load "grafana"

NAME="grafana"
KEEP="${GRAFANA_KEEP_DATA:-true}"

info "grafana remove — stopping/removing container"
if docker inspect "$NAME" >/dev/null 2>&1; then
  if is_dry_run; then info "DRY-RUN docker rm -f $NAME"; else docker rm -f "$NAME" >/dev/null; fi
  echo "updated:container:$NAME:removed"
else
  info "container $NAME not present"
fi

if [[ "$KEEP" != "true" ]]; then
  info "Purging data/config dirs"
  for d in "${GRAFANA_DATA_DIR:-./var/state/grafana/data}" \
           "${GRAFANA_LOG_DIR:-./var/state/grafana/logs}" \
           "${GRAFANA_PROVISIONING_DIR:-./var/state/grafana/provisioning}" \
           "${GRAFANA_CONFIG_DIR:-./var/state/grafana/config}"; do
    if [[ -d "$d" ]]; then
      if is_dry_run; then info "DRY-RUN rm -rf $d"; else rm -rf "$d"; fi
      echo "updated:purged:$d"
    fi
  done
else
  info "Keeping data/config dirs (set GRAFANA_KEEP_DATA=false to purge)"
fi

info "Done."
