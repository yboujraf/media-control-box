# Security

- Never commit `env/*.env` or `env/*.local.env`.
- Use `env/*.env.example` for placeholders only.
- Cloudflare token: scope to specific zone with Zone.DNS:Edit (+ Zone.Zone:Read).
- Private keys: 0600, root-owned.
- TURN DNS record must be DNS-only (no Cloudflare proxy).
- Metrics endpoints bind to 127.0.0.1 or docker network only.
- UFW default deny; open only required ports.
