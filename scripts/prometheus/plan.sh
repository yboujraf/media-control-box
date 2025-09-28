SERVICE_NAME="prometheus"
#!/usr/bin/env bash
set -euo pipefail
# SERVICE_NAME will be injected by sed below

# Load shared libs
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
env_load "$SERVICE_NAME"

# Optional: pick libs you need; they can be safely sourced even if unused
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/dns_cf.sh"      || true
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/cert_cf.sh"     || true
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/sys_pkg.sh"     || true
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/docker.sh"      || true
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/net.sh"         || true

log_file="$(today_log_path "$SERVICE_NAME")"
logln(){ printf "%s\n" "$*" | tee -a "$log_file"; }

cmd="$(basename "$0")"

case "$cmd" in
  plan.sh)
    logln "PLAN: $SERVICE_NAME — describe what would change (no side-effects)"
    # Example: validate required env here (no secrets printed)
    # require_vars EXAMPLE_VAR
    ;;
  apply.sh)
    logln "APPLY: $SERVICE_NAME — performing idempotent changes"
    # Example scaffold:
    # if is_dry_run; then logln "DRY-RUN: would do X"; exit 0; fi
    # ... do work with libs ...
    ;;
  remove.sh)
    logln "REMOVE: $SERVICE_NAME — stopping/removing only this service's artifacts"
    # ... stop containers, remove firewall rules owned by this service (idempotent) ...
    ;;
  status.sh)
    logln "STATUS: $SERVICE_NAME — quick health summary"
    # ... show ports, container status, version, endpoints ...
    ;;
  *)
    err "Unknown command"; exit 1;;
esac
