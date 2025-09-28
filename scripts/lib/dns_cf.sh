#!/usr/bin/env bash
# dns_cf.sh — Cloudflare DNS CRUD (A/AAAA), idempotent, respects DRY_RUN
set -euo pipefail
# requires: core.sh
# env: CF_API_TOKEN, CF_ZONE, optional DNS_TTL (default auto)

# internal cache
__CF_ZONE_ID=""

cf_init() {
  require_cmd curl jq
  require_vars CF_API_TOKEN CF_ZONE
  local url="https://api.cloudflare.com/client/v4/zones?name=$(printf %s "$CF_ZONE" | sed 's:/:%2F:g')&status=active"
  local resp
  resp="$(curl -sS -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" "$url")"
  __CF_ZONE_ID="$(echo "$resp" | jq -r '.result[0].id // empty')"
  [[ -n "$__CF_ZONE_ID" ]] || { err "Cloudflare zone not found: $CF_ZONE"; exit 1; }
  info "Cloudflare zone resolved: $CF_ZONE ($__CF_ZONE_ID)"
}

# cf_upsert <name> <type:A|AAAA> <content_ip> <proxied:true|false> [ttl:auto|seconds]
cf_upsert() {
  local name="${1:?}"; local type="${2:?}"; local content="${3:-}"; local prox="${4:-false}"; local ttl="${5:-${DNS_TTL:-auto}}"
  [[ -n "$content" ]] || { info "cf_upsert: $name $type skipped (empty content)"; return 0; }
  [[ -n "$__CF_ZONE_ID" ]] || cf_init

  local auth=(-H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
  local list_url="https://api.cloudflare.com/client/v4/zones/${__CF_ZONE_ID}/dns_records?type=${type}&name=${name}"
  local rec resp rid rip rprox
  resp="$(curl -sS "${auth[@]}" "$list_url")"
  rid="$(echo "$resp" | jq -r '.result[0].id // empty')"
  rip="$(echo "$resp" | jq -r '.result[0].content // empty')"
  rprox="$(echo "$resp" | jq -r '.result[0].proxied // empty')"

  local prox_bool=false
  [[ "$prox" == "true" ]] && prox_bool=true

  local ttl_json
  if [[ "$ttl" == "auto" ]]; then ttl_json='"ttl":1'; else ttl_json='"ttl":'"$ttl"; fi

  if [[ -n "$rid" ]]; then
    if [[ "$rip" == "$content" && "$rprox" == "$prox_bool" ]]; then
      echo "unchanged:DNS $name $type -> $content (proxied=$prox_bool)"
      return 0
    fi
    if is_dry_run; then
      echo "DRY-RUN update: $name $type $rip→$content (prox $rprox→$prox_bool)"
      return 0
    fi
    curl -sS -X PATCH "${auth[@]}" \
      "https://api.cloudflare.com/client/v4/zones/${__CF_ZONE_ID}/dns_records/${rid}" \
      --data "$(printf '{"type":"%s","name":"%s","content":"%s","proxied":%s,%s}' "$type" "$name" "$content" "$prox_bool" "$ttl_json")" >/dev/null
    echo "updated:DNS $name $type -> $content (proxied=$prox_bool)"
  else
    if is_dry_run; then
      echo "DRY-RUN create: $name $type $content (proxied=$prox_bool)"
      return 0
    fi
    curl -sS -X POST "${auth[@]}" \
      "https://api.cloudflare.com/client/v4/zones/${__CF_ZONE_ID}/dns_records" \
      --data "$(printf '{"type":"%s","name":"%s","content":"%s","proxied":%s,%s}' "$type" "$name" "$content" "$prox_bool" "$ttl_json")" >/dev/null
    echo "created:DNS $name $type -> $content (proxied=$prox_bool)"
  fi
}

# cf_delete <name> <type>
cf_delete() {
  local name="${1:?}"; local type="${2:?}"
  [[ -n "$__CF_ZONE_ID" ]] || cf_init
  local auth=(-H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
  local resp rid
  resp="$(curl -sS "${auth[@]}" "https://api.cloudflare.com/client/v4/zones/${__CF_ZONE_ID}/dns_records?type=${type}&name=${name}")"
  rid="$(echo "$resp" | jq -r '.result[0].id // empty')"
  [[ -n "$rid" ]] || { info "cf_delete: no such record $name $type"; return 0; }
  if is_dry_run; then
    echo "DRY-RUN delete: $name $type"
    return 0
  fi
  curl -sS -X DELETE "${auth[@]}" \
    "https://api.cloudflare.com/client/v4/zones/${__CF_ZONE_ID}/dns_records/${rid}" >/dev/null
  echo "deleted:DNS $name $type"
}
