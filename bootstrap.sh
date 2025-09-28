set -euo pipefail
cd /opt/media-control-box

# 0) Ensure library dir exists (you already added libs earlier)
mkdir -p scripts/lib

# 1) Create service folders
mkdir -p scripts/{dns,certs,turn,proxy,prometheus,grafana}

# 2) Helper: make a 4-file stub set for a service
mk_service_stubs() {
  svc="$1"
  dir="scripts/$svc"
  for f in plan apply remove status; do
    cat > "$dir/$f.sh" <<'EOF'
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
EOF
  done
  # Inject SERVICE_NAME into each file
  sed -i "1i SERVICE_NAME=\"$svc\"" "$dir/"*.sh
  chmod +x "$dir/"*.sh
}

# 3) Generate stubs for each service
for svc in dns certs turn proxy prometheus grafana; do
  mk_service_stubs "$svc"
done

# 4) Add brief README markers per service (optional, helps navigation)
for svc in dns certs turn proxy prometheus grafana; do
  cat > "scripts/$svc/README.md" <<EOF
# $svc service scripts

- plan.sh   — dry-run; prints what would happen
- apply.sh  — idempotent apply
- remove.sh — clean removal of only this service
- status.sh — quick health summary

These scripts read: env/global.env, env/${svc}.env (+ *.local.env).
They write logs to var/logs/${svc}/ and state to var/state/${svc}/.
EOF
done

# 5) Commit
git add scripts/dns scripts/certs scripts/turn scripts/proxy scripts/prometheus scripts/grafana
git commit -m "chore(scripts): adopt service folders with uniform plan/apply/remove/status stubs"
git push
