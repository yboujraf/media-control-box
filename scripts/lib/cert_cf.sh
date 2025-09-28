#!/usr/bin/env bash
# cert_cf.sh — Let's Encrypt via Cloudflare DNS-01 (certbot + CF plugin)
set -euo pipefail
# requires: core.sh, sys_pkg.sh
# env: SYS_ADMIN_EMAIL, CF_API_TOKEN, CERT_ECDSA=true|false(default true), CERT_WILDCARD_PAIR=true|false(default false)

le_prepare() {
  require_vars SYS_ADMIN_EMAIL CF_API_TOKEN
  local ini="/root/.secrets/certbot/cloudflare.ini"
  if is_dry_run; then
    info "DRY-RUN le_prepare (would install certbot & write $ini)"
    return 0
  fi
  install -d -m 0700 /root/.secrets/certbot
  printf "dns_cloudflare_api_token = %s\n" "${CF_API_TOKEN}" > "$ini"
  chmod 600 "$ini"
  if ! command -v snap >/dev/null 2>&1; then
    apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y snapd
    snap install core || true; snap refresh core || true
  fi
  snap install --classic certbot || true
  ln -sf /snap/bin/certbot /usr/bin/certbot
  snap set certbot trust-plugin-with-root=ok || true
  snap install certbot-dns-cloudflare || true
}

# le_issue <domain> [deploy_hook_script_path]
le_issue() {
  local domain="${1:?}"; local deploy_hook="${2:-}"
  local ini="/root/.secrets/certbot/cloudflare.ini"

  # In DRY_RUN, just print what would happen and exit successfully.
  if is_dry_run; then
    local key_desc="ECDSA P-384"; [[ "${CERT_ECDSA:-true}" == "true" ]] || key_desc="RSA 4096"
    local domains=" -d ${domain}"
    [[ "${CERT_WILDCARD_PAIR:-false}" == "true" ]] && domains="${domains} -d *.${domain#*.}"
    info "DRY-RUN certbot certonly${domains} (key: ${key_desc}) via CF DNS-01"
    [[ -n "$deploy_hook" ]] && info "DRY-RUN deploy hook: $deploy_hook"
    return 0
  fi

  require_cmd certbot
  [[ -f "$ini" ]] || { err "Cloudflare ini missing: $ini (run le_prepare)"; exit 1; }

  local key_type=(--key-type ecdsa --elliptic-curve secp384r1)
  [[ "${CERT_ECDSA:-true}" == "true" ]] || key_type=(--rsa-key-size 4096)

  local domains=(-d "$domain")
  [[ "${CERT_WILDCARD_PAIR:-false}" == "true" ]] && domains+=(-d "*.${domain#*.}")

  local args=(
    --agree-tos -m "${SYS_ADMIN_EMAIL}"
    --non-interactive
    --dns-cloudflare --dns-cloudflare-credentials "$ini"
    --dns-cloudflare-propagation-seconds "${CF_PROPAGATION_SECONDS:-30}"
    "${key_type[@]}"
    --keep-until-expiring --expand
    "${domains[@]}"
  )
  [[ -n "$deploy_hook" ]] && args+=(--deploy-hook "$deploy_hook")

  certbot certonly "${args[@]}"
}

# le_report <domain>
le_report() {
  local domain="${1:?}"
  local cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  [[ -f "$cert" ]] || { err "No cert at $cert"; return 1; }
  openssl x509 -in "$cert" -noout -subject -issuer -enddate || true
}

# le_install_hook <name> <script_content>
le_install_hook() {
  local name="${1:?}"; local content="${2:?}"
  local hook="/etc/letsencrypt/renewal-hooks/deploy/${name}.sh"
  if is_dry_run; then
    info "DRY-RUN write deploy hook $hook"
    return 0
  fi
  install -d -m 0755 "$(dirname "$hook")"
  printf "%s\n" "$content" | install -D -m 0755 /dev/stdin "$hook"
  echo "updated:$hook"
}
