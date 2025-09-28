#!/usr/bin/env bash
# patch.sh — unify on write_if_changed and update service scripts
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CORE="$ROOT/scripts/lib/core.sh"

echo "[*] Repo root: $ROOT"

# 1) Make sure scripts/lib/core.sh has a single canonical helper: write_if_changed
if [[ ! -f "$CORE" ]]; then
  echo "[x] Missing $CORE — aborting." >&2
  exit 1
fi

echo "[*] Ensuring core.sh exposes only write_if_changed (no duplicates)..."

# If there's a legacy function named write_file_if_changed, convert its name to write_if_changed
# (only if the canonical write_if_changed is NOT present)
if ! grep -q '^[[:space:]]*write_if_changed()[[:space:]]*{' "$CORE"; then
  if grep -q '^[[:space:]]*write_file_if_changed()[[:space:]]*{' "$CORE"; then
    echo "    - Renaming legacy write_file_if_changed() to write_if_changed() in core.sh"
    sed -i 's/^[[:space:]]*write_file_if_changed()[[:space:]]*{/write_if_changed() {/g' "$CORE"
  fi
fi

# Remove any simple alias/wrapper of write_file_if_changed if it still exists
# (a block that starts with 'write_file_if_changed() {' and ends at the matching '}' on its own line)
if grep -q '^[[:space:]]*write_file_if_changed()[[:space:]]*{' "$CORE"; then
  echo "    - Removing duplicate write_file_if_changed() definition block from core.sh"
  awk '
    BEGIN{skip=0}
    /^[[:space:]]*write_file_if_changed\(\)[[:space:]]*{/ {skip=1; next}
    skip==1 && /^[[:space:]]*}[[:space:]]*$/ {skip=0; next}
    skip==0 {print}
  ' "$CORE" > "$CORE.tmp" && mv "$CORE.tmp" "$CORE"
fi

# Final check: core must have write_if_changed
if ! grep -q '^[[:space:]]*write_if_changed()[[:space:]]*{' "$CORE"; then
  echo "[x] core.sh does not define write_if_changed() — please add it (it’s used by TURN). Aborting." >&2
  exit 1
fi

echo "[*] core.sh OK (single write_if_changed)."

# 2) Update service scripts to call write_if_changed (Grafana + Proxy only; TURN left untouched)
update_calls() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    echo "[*] Updating write_file_if_changed -> write_if_changed in $dir"
    grep -RIl --exclude-dir='.git' --exclude='*.tmp' 'write_file_if_changed' "$dir" | while read -r f; do
      echo "    - $f"
      sed -i 's/write_file_if_changed/write_if_changed/g' "$f"
    done
  fi
}

update_calls "$ROOT/scripts/grafana"
update_calls "$ROOT/scripts/proxy"

# 3) Ensure execute bits on service scripts (harmless if already set)
for d in "$ROOT/scripts/grafana" "$ROOT/scripts/proxy"; do
  if [[ -d "$d" ]]; then
    echo "[*] Ensuring executables in $d"
    chmod +x "$d"/*.sh 2>/dev/null || true
  fi
done

echo "[*] Patch complete."
echo
echo "Next:"
echo "  - Run: DRY_RUN=true scripts/grafana/plan.sh"
echo "         DRY_RUN=true scripts/grafana/apply.sh"
echo "  - Then: scripts/grafana/apply.sh && scripts/grafana/status.sh"
echo "  - Proxy will be added/updated separately (it already uses write_if_changed now)."
