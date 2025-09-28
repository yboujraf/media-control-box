#!/usr/bin/env bash
set -euo pipefail
SERVICE_NAME="turn"

. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/core.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/dns_cf.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/cert_cf.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/docker.sh"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/net.sh"

env_load "$SERVICE_NAME"
log_file="$(today_log_path "$SERVICE_NAME")"; logln(){ printf "%s\n" "$*" | tee -a "$log_file"; }

logln "PLAN: TURN on ${TURN_DOMAIN:-<unset>}"
require_vars TURN_DOMAIN TURN_REALM TURN_USER TURN_PASS TURN_MIN_PORT TURN_MAX_PORT
info "IPv4 public: ${TURN_PUBLIC_IP4:-<none>}"
info "IPv6 public: ${TURN_PUBLIC_IP6:-<none>}"
info "IPv6 enabled: ${TURN_IPV6_ENABLE:-false}"
info "Relay range: ${TURN_MIN_PORT}-${TURN_MAX_PORT}"
info "Docker image: ${TURN_DOCKER_IMAGE:-coturn/coturn:latest}"

logln "- DNS: will upsert A/AAAA for $TURN_DOMAIN (proxied=false)"
logln "- CERT: will issue/renew LE cert for $TURN_DOMAIN via CF DNS-01"
logln "- CONFIG: will render /etc/coturn/turnserver.conf"
logln "- CONTAINER: will run 'coturn' with --network host and RO config mount"
logln "- FIREWALL: will allow 3478/udp+tcp, 5349/tcp, and ${TURN_MIN_PORT}:${TURN_MAX_PORT}/udp"

logln "No changes made. Use DRY_RUN=true scripts/turn/apply.sh to simulate apply."
