# proxy service scripts

- plan.sh   — dry-run; prints what would happen
- apply.sh  — idempotent apply
- remove.sh — clean removal of only this service
- status.sh — quick health summary

These scripts read: env/global.env, env/proxy.env (+ *.local.env).
They write logs to var/logs/proxy/ and state to var/state/proxy/.
