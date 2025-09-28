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
