#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

backup() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -a "$f" "${f}.bak.$(date +%s)"
  echo "[*] Backed up $f -> ${f}.bak.*"
}

ensure_dir() {
  install -d -m 0755 "$1"
}

# 1) Ensure env directory
ensure_dir "$ROOT/env"

# 2) Write fresh env/grafana.env.example (placeholders only)
EX="$ROOT/env/grafana.env.example"
backup "$EX"
cat >"$EX" <<'EOF'
# =========================
# GRAFANA SERVICE (example)
# =========================

# Enable/disable service
GRAFANA_ENABLE="true"

# Domain used later by the nginx reverse-proxy (optional here)
GRAFANA_DOMAIN="grafana.example.com"

# Bind inside the container; host binding is restricted separately via docker -p
# Keep 0.0.0.0 (container-internal), host binding will still be 127.0.0.1:<port>:3000
GRAFANA_LISTEN_HOST="0.0.0.0"
GRAFANA_HTTP_PORT="3000"

# Image & user/group
GRAFANA_DOCKER_IMAGE="grafana/grafana-oss:latest"
GRAFANA_UID="472"
GRAFANA_GID="472"

# Host paths (created with UID:GID above)
GRAFANA_DATA_DIR="./var/state/grafana/data"
GRAFANA_LOG_DIR="./var/state/grafana/logs"
GRAFANA_PROVISIONING_DIR="./var/state/grafana/provisioning"
GRAFANA_CONFIG_DIR="./var/state/grafana/config"

# Admin (use local env for real secrets)
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASS="CHANGEME"
# If you later automate dashboards/datasources via API,
# keep token ONLY in grafana.local.env (never commit real tokens)
GRAFANA_API_TOKEN="CHANGEME"

# Remove volumes on 'remove.sh' when set to "false" -> purges data/config
GRAFANA_KEEP_DATA="true"
EOF
echo "updated:$EX"

# 3) Normalize env/grafana.env (no secrets; placeholders)
GE="$ROOT/env/grafana.env"
if [[ -f "$GE" ]]; then
  backup "$GE"
  # Load current file, rewrite keys, scrub secrets, update paths
  awk '
    BEGIN{FS="="; OFS="="}
    # Normalize key names (MON_* -> GRAFANA_*)
    {
      gsub(/^MON_ENABLE[[:space:]]*/, "GRAFANA_ENABLE");
      gsub(/^MON_DOMAIN[[:space:]]*/, "GRAFANA_DOMAIN");
      gsub(/^MON_HTTP_PORT[[:space:]]*/, "GRAFANA_HTTP_PORT");

      gsub(/^MON_DATA_DIR[[:space:]]*/, "GRAFANA_DATA_DIR");
      gsub(/^MON_LOG_DIR[[:space:]]*/, "GRAFANA_LOG_DIR");
      gsub(/^MON_PROVISIONING_DIR[[:space:]]*/, "GRAFANA_PROVISIONING_DIR");
      gsub(/^MON_CONFIG_DIR[[:space:]]*/, "GRAFANA_CONFIG_DIR");

      gsub(/^MON_DASH_APPS[[:space:]]*/, "GRAFANA_DASH_APPS");
      gsub(/^MON_DASH_PRUNE[[:space:]]*/, "GRAFANA_DASH_PRUNE");

      # Remove Prometheus bits if present (phase 2 feature)
      if ($1 ~ /^PROM_/) next;

      # Path corrections: /mon/ -> /grafana/
      gsub(/var\/state\/mon\/grafana/, "var/state/grafana");
      gsub(/var\/logs\/mon/, "var/state/grafana/logs");

      print
    }
  ' "$GE" > "$GE.tmp"

  # Ensure required keys exist with safe defaults and scrub secrets
  # Replace API token with placeholder, admin pass with CHANGEME
  grep -q '^GRAFANA_ENABLE=' "$GE.tmp" || echo 'GRAFANA_ENABLE="true"' >> "$GE.tmp"
  sed -i 's/^GRAFANA_API_TOKEN=.*/GRAFANA_API_TOKEN="CHANGEME"/' "$GE.tmp"
  sed -i 's/^GRAFANA_ADMIN_PASS=.*/GRAFANA_ADMIN_PASS="CHANGEME"/' "$GE.tmp"

  # Ensure listen host/port present
  grep -q '^GRAFANA_LISTEN_HOST=' "$GE.tmp" || echo 'GRAFANA_LISTEN_HOST="0.0.0.0"' >> "$GE.tmp"
  grep -q '^GRAFANA_HTTP_PORT=' "$GE.tmp" || echo 'GRAFANA_HTTP_PORT="3000"' >> "$GE.tmp"

  # Ensure image, uid/gid and dirs
  grep -q '^GRAFANA_DOCKER_IMAGE=' "$GE.tmp" || echo 'GRAFANA_DOCKER_IMAGE="grafana/grafana-oss:latest"' >> "$GE.tmp"
  grep -q '^GRAFANA_UID=' "$GE.tmp" || echo 'GRAFANA_UID="472"' >> "$GE.tmp"
  grep -q '^GRAFANA_GID=' "$GE.tmp" || echo 'GRAFANA_GID="472"' >> "$GE.tmp"
  grep -q '^GRAFANA_DATA_DIR=' "$GE.tmp" || echo 'GRAFANA_DATA_DIR="./var/state/grafana/data"' >> "$GE.tmp"
  grep -q '^GRAFANA_LOG_DIR=' "$GE.tmp" || echo 'GRAFANA_LOG_DIR="./var/state/grafana/logs"' >> "$GE.tmp"
  grep -q '^GRAFANA_PROVISIONING_DIR=' "$GE.tmp" || echo 'GRAFANA_PROVISIONING_DIR="./var/state/grafana/provisioning"' >> "$GE.tmp"
  grep -q '^GRAFANA_CONFIG_DIR=' "$GE.tmp" || echo 'GRAFANA_CONFIG_DIR="./var/state/grafana/config"' >> "$GE.tmp"
  grep -q '^GRAFANA_KEEP_DATA=' "$GE.tmp" || echo 'GRAFANA_KEEP_DATA="true"' >> "$GE.tmp"

  mv "$GE.tmp" "$GE"
  echo "updated:$GE"
else
  # If missing, create a minimal committed (no secrets) file from example
  cp -a "$EX" "$GE"
  echo "created:$GE (from example)"
fi

# 4) Normalize env/grafana.local.env (real values allowed; migrate MON_* ➜ GRAFANA_*)
GLE="$ROOT/env/grafana.local.env"
if [[ -f "$GLE" ]]; then
  backup "$GLE"
  awk '
    BEGIN{FS="="; OFS="="}
    {
      gsub(/^MON_ENABLE[[:space:]]*/, "GRAFANA_ENABLE");
      gsub(/^MON_DOMAIN[[:space:]]*/, "GRAFANA_DOMAIN");
      gsub(/^MON_HTTP_PORT[[:space:]]*/, "GRAFANA_HTTP_PORT");

      gsub(/^MON_DATA_DIR[[:space:]]*/, "GRAFANA_DATA_DIR");
      gsub(/^MON_LOG_DIR[[:space:]]*/, "GRAFANA_LOG_DIR");
      gsub(/^MON_PROVISIONING_DIR[[:space:]]*/, "GRAFANA_PROVISIONING_DIR");
      gsub(/^MON_CONFIG_DIR[[:space:]]*/, "GRAFANA_CONFIG_DIR");

      # Path corrections
      gsub(/var\/state\/mon\/grafana/, "var/state/grafana");
      gsub(/var\/logs\/mon/, "var/state/grafana/logs");

      print
    }
  ' "$GLE" > "$GLE.tmp"

  # Ensure keys exist
  grep -q '^GRAFANA_LISTEN_HOST=' "$GLE.tmp" || echo 'GRAFANA_LISTEN_HOST="0.0.0.0"' >> "$GLE.tmp"
  grep -q '^GRAFANA_HTTP_PORT=' "$GLE.tmp" || echo 'GRAFANA_HTTP_PORT="3000"' >> "$GLE.tmp"
  grep -q '^GRAFANA_DOCKER_IMAGE=' "$GLE.tmp" || echo 'GRAFANA_DOCKER_IMAGE="grafana/grafana-oss:latest"' >> "$GLE.tmp"
  grep -q '^GRAFANA_UID=' "$GLE.tmp" || echo 'GRAFANA_UID="472"' >> "$GLE.tmp"
  grep -q '^GRAFANA_GID=' "$GLE.tmp" || echo 'GRAFANA_GID="472"' >> "$GLE.tmp"
  grep -q '^GRAFANA_DATA_DIR=' "$GLE.tmp" || echo 'GRAFANA_DATA_DIR="./var/state/grafana/data"' >> "$GLE.tmp"
  grep -q '^GRAFANA_LOG_DIR=' "$GLE.tmp" || echo 'GRAFANA_LOG_DIR="./var/state/grafana/logs"' >> "$GLE.tmp"
  grep -q '^GRAFANA_PROVISIONING_DIR=' "$GLE.tmp" || echo 'GRAFANA_PROVISIONING_DIR="./var/state/grafana/provisioning"' >> "$GLE.tmp"
  grep -q '^GRAFANA_CONFIG_DIR=' "$GLE.tmp" || echo 'GRAFANA_CONFIG_DIR="./var/state/grafana/config"' >> "$GLE.tmp"
  grep -q '^GRAFANA_KEEP_DATA=' "$GLE.tmp" || echo 'GRAFANA_KEEP_DATA="true"' >> "$GLE.tmp"

  mv "$GLE.tmp" "$GLE"
  echo "updated:$GLE"
else
  # Create an empty local env for you to fill real values
  cat >"$GLE" <<'EOF'
# Local-only secrets/overrides (NOT committed)
GRAFANA_ENABLE="true"
GRAFANA_DOMAIN="grafana.by-research.be"

GRAFANA_LISTEN_HOST="0.0.0.0"
GRAFANA_HTTP_PORT="3000"

GRAFANA_DOCKER_IMAGE="grafana/grafana-oss:latest"
GRAFANA_UID="472"
GRAFANA_GID="472"

GRAFANA_DATA_DIR="./var/state/grafana/data"
GRAFANA_LOG_DIR="./var/state/grafana/logs"
GRAFANA_PROVISIONING_DIR="./var/state/grafana/provisioning"
GRAFANA_CONFIG_DIR="./var/state/grafana/config"

# Real credentials should live here (not in grafana.env)
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASS="CHANGEME"
GRAFANA_API_TOKEN="CHANGEME"

GRAFANA_KEEP_DATA="true"
EOF
  echo "created:$GLE (fill your real secrets here)"
fi

# 5) Move old mon data dirs if they exist
if [[ -d "$ROOT/var/state/mon" ]]; then
  echo "[*] Detected legacy var/state/mon — migrating folders"
  ensure_dir "$ROOT/var/state/grafana"
  [[ -d "$ROOT/var/state/mon/grafana" ]] && mv "$ROOT/var/state/mon/grafana" "$ROOT/var/state/grafana/data" || true
  [[ -d "$ROOT/var/logs/mon" ]] && mkdir -p "$ROOT/var/state/grafana" && mv "$ROOT/var/logs/mon" "$ROOT/var/state/grafana/logs" || true
fi

# 6) Ensure provisioning folder structure exists (silences Grafana warnings)
ensure_dir "$ROOT/var/state/grafana/provisioning/datasources"
ensure_dir "$ROOT/var/state/grafana/provisioning/dashboards"
ensure_dir "$ROOT/var/state/grafana/provisioning/plugins"
ensure_dir "$ROOT/var/state/grafana/config"

# 7) Touch a minimal disabled datasource file (commented) — optional
DS="$ROOT/var/state/grafana/provisioning/datasources/README.keep"
[[ -f "$DS" ]] || {
  cat >"$DS" <<'EOF'
# Put datasource YAMLs here (e.g., Prometheus).
# Example file (uncomment & edit to use):
#
# apiVersion: 1
# datasources:
#   - name: Prometheus
#     type: prometheus
#     access: proxy
#     url: http://127.0.0.1:9090
#     isDefault: true
#     jsonData:
#       timeInterval: 15s
EOF
  echo "created:$DS"
}

# 8) Remind about .gitignore policy
GI="$ROOT/.gitignore"
if ! grep -qE '^/env/.*\.local\.env$' "$GI" 2>/dev/null; then
  echo '/env/*.local.env' >> "$GI"
  echo "updated:.gitignore -> /env/*.local.env"
fi

echo
echo "[OK] Env files normalized to GRAFANA_*. TURN remains untouched."
echo "Next: re-run ./scripts/grafana/apply.sh"
