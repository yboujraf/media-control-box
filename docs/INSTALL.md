# Install (high level)

1) Prepare env files (no secrets in git)
   - Copy examples: `cp env/*.env.example env/`
   - Fill only what you need per service.
   - Put secrets in `*.local.env` (gitignored).

2) Order of operations (per concern)
   - Docker runtime → DNS (Cloudflare) → Certificates → TURN → Proxy → Apps → Monitoring.

3) Run a single service
   - Edit `env/global.env` + `<service>.env` (+ optional `*.local.env`).
   - Execute only that service’s script(s) in `scripts/`.

4) Idempotency
   - Scripts only write when content changes.
   - Re-running is safe; outputs show `updated:` vs `unchanged:`.
