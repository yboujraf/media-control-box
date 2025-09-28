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
