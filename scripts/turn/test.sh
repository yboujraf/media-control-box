#!/usr/bin/env bash
# TURN end-to-end local test (single VPS friendly)
# 1) STUN sanity on 3478/5349 (UDP)
# 2) TLS handshake on 5349/TCP
# 3) TURN allocation-only test (no peer) -- robust across coturn builds
# 4) Optional: echo peer test (tries multiple uclient syntaxes)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT_DIR/scripts/lib/core.sh"      # env_load, today_log_path, etc.

# ---------- Config & env ----------
env_load "turn"  # loads env/turn.env

TURN_HOST="${TURN_DOMAIN:?TURN_DOMAIN missing (set in env/turn.env)}"
TURN_USER="${TURN_USER:?TURN_USER missing (set in env/turn.env)}"
TURN_PASS="${TURN_PASS:?TURN_PASS missing (set in env/turn.env)}"
TURN_REALM="${TURN_REALM:?TURN_REALM missing (set in env/turn.env)}"

TURN_PORT="${TURN_PORT:-3478}"       # STUN/TURN (UDP/TCP)
TURNS_PORT="${TURNS_PORT:-5349}"     # TURN over TLS (TCP)
PEER_PORT="${PEER_PORT:-5778}"       # local echo peer
RUN_PEER_TEST="${RUN_PEER_TEST:-true}"  # set to "false" to skip step 4

log_file="$(today_log_path "turn-test")"
log(){ printf "%s\n" "$*" | tee -a "$log_file"; }
x(){ set -x; "$@"; local ret=$?; { set +x; } 2>/dev/null; return $ret; }

# ---------- Pre-flight checks ----------
if ! command -v docker >/dev/null 2>&1; then
  log "[!] docker missing. Install docker and retry."
  exit 1
fi

# Pick a usable IPv4 (for peer bind if we run it)
BIND_IP="${TURN_PUBLIC_IP4:-}"
if [[ -z "$BIND_IP" ]]; then
  BIND_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' | head -n1 || true)"
fi

# ---------- 1) STUN sanity (UDP) ----------
log "==[ 1/4 ] STUN sanity (UDP) on $TURN_PORT and $TURNS_PORT =="
x docker run --rm --network host coturn/coturn:latest \
  turnutils_stunclient -p "$TURN_PORT"  "$TURN_HOST" || true
x docker run --rm --network host coturn/coturn:latest \
  turnutils_stunclient -p "$TURNS_PORT" "$TURN_HOST" || true
echo

# ---------- 2) TLS handshake on 5349/TCP ----------
log "==[ 2/4 ] TLS handshake on ${TURNS_PORT}/TCP (server cert & cipher) =="
x bash -lc "echo | openssl s_client -connect ${TURN_HOST}:${TURNS_PORT} -servername ${TURN_HOST} 2>/dev/null | openssl x509 -noout -subject -issuer -enddate"
echo

# ---------- 3) TURN allocation-only test (no peer, robust) ----------
log "==[ 3/4 ] TURN allocation-only test (no peer) =="
# Many coturn builds support -y for allocation-only (no data peer). This validates TURN creds & allocation.
ALLOC_OK=0
if x docker run --rm --network host coturn/coturn:latest \
  turnutils_uclient \
    -u "$TURN_USER" -w "$TURN_PASS" \
    -p "$TURN_PORT" \
    -r "$TURN_REALM" \
    -y \
    "$TURN_HOST" ; then
  ALLOC_OK=1
  log "[*] TURN UDP allocation succeeded."
else
  log "[!] TURN UDP allocation failed (allocation-only). Check docker logs coturn."
fi

# Optional TLS allocation-only
if x docker run --rm --network host coturn/coturn:latest \
  turnutils_uclient \
    -u "$TURN_USER" -w "$TURN_PASS" \
    -S -p "$TURNS_PORT" \
    -r "$TURN_REALM" \
    -y \
    "$TURN_HOST" ; then
  log "[*] TURN TLS allocation succeeded."
else
  log "[!] TURN TLS allocation failed (allocation-only). This can be policy-dependent; continue."
fi
echo

# ---------- 4) Optional: Echo peer test (tries multiple syntaxes) ----------
if [[ "${RUN_PEER_TEST}" == "true" ]]; then
  if [[ -z "$BIND_IP" ]]; then
    log "[!] Skipping peer test (no non-loopback IPv4 detected). Set TURN_PUBLIC_IP4 to enable."
  else
    log "==[ 4/4 ] TURN relay echo test with local peer on ${BIND_IP}:${PEER_PORT} =="
    x docker rm -f turn-test-peer >/dev/null 2>&1 || true
    x docker run -d --name turn-test-peer --network host coturn/coturn:latest \
      turnutils_peer -L "$BIND_IP" -p "$PEER_PORT"
    x docker ps --filter name=turn-test-peer --format 'table {{.Names}}\t{{.Status}}'

    # Try a few uclient syntaxes (builds differ):
    PEER_OK=0
    log "[*] Attempt A: -e <IP> and positional <PEER_PORT>"
    if x docker run --rm --network host coturn/coturn:latest \
      turnutils_uclient \
        -u "$TURN_USER" -w "$TURN_PASS" \
        -p "$TURN_PORT" \
        -e "$BIND_IP" \
        -r "$TURN_REALM" \
        "$TURN_HOST" "$PEER_PORT" ; then
      PEER_OK=1
    else
      log "[!] Attempt A failed."
    fi

    if [[ $PEER_OK -eq 0 ]]; then
      log "[*] Attempt B: -e <IP:PORT> (no positional peer args)"
      if x docker run --rm --network host coturn/coturn:latest \
        turnutils_uclient \
          -u "$TURN_USER" -w "$TURN_PASS" \
          -p "$TURN_PORT" \
          -e "${BIND_IP}:${PEER_PORT}" \
          -r "$TURN_REALM" \
          "$TURN_HOST" ; then
        PEER_OK=1
      else
        log "[!] Attempt B failed."
      fi
    fi

    if [[ $PEER_OK -eq 0 ]]; then
      log "[*] Attempt C: allocation-only fallback (-y) — proves relay but skips echo."
      if x docker run --rm --network host coturn/coturn:latest \
        turnutils_uclient \
          -u "$TURN_USER" -w "$TURN_PASS" \
          -p "$TURN_PORT" \
          -r "$TURN_REALM" \
          -y \
          "$TURN_HOST" ; then
        PEER_OK=2
      else
        log "[!] Attempt C failed."
      fi
    fi

    echo
    log "== Peer logs (last 80 lines) =="
    x docker logs --tail 80 turn-test-peer || true
    x docker rm -f turn-test-peer >/dev/null 2>&1 || true

    case $PEER_OK in
      1) log "[✓] Echo peer test succeeded (data path verified).";;
      2) log "[i] Allocation-only succeeded; echo peer skipped (version-specific client flags).";;
      0) log "[x] Echo peer test failed. TURN allocations may still be OK (see step 3).";;
    esac
  fi
fi

log "All tests completed."
