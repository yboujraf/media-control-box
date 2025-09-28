# certs service scripts

- plan.sh   — dry-run; prints what would happen
- apply.sh  — idempotent apply
- remove.sh — clean removal of only this service
- status.sh — quick health summary

These scripts read: env/global.env, env/certs.env (+ *.local.env).
They write logs to var/logs/certs/ and state to var/state/certs/.
