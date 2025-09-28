# media-control-box

Self-hosted media infrastructure on one VPS:
- TURN (coturn, Docker)
- VDO.Ninja (self-hosted)
- Broadcast-Box (Docker)
- Nginx reverse proxy (Docker, vhosts)
- Prometheus + Grafana (observability)
- Let's Encrypt (Cloudflare DNS-01)

## Principles
- Separation of concerns: per-service env, scripts, logs, metrics, health.
- Idempotent scripts: re-runs are safe.
- Metrics-first: each service exposes a Prometheus endpoint (local-only).

## Layout
- `scripts/` — one script per service (plus shared `90_lib.sh`)
- `env/` — `global.env[.example]` + one `*.env[.example]` per service
- `var/` — per-service logs and state (not committed)
- `docs/` — install, uninstall, operations, security

## Quick start
1. Copy examples → working envs:
   cp env/*.env.example env/
   then edit env/*.env and put secrets in env/*.local.env (gitignored)

2. Bring up services in order:
   Docker runtime → DNS → Certs → TURN → Proxy → Apps → Monitoring
