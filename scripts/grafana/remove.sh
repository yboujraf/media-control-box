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
