# Clawops Reliability + Autonomous Ops Package

This package implements a no-GitOps operations workflow for a 4GB host.

It provides:

- baseline apply, validate, and rollback
- release watch + immediate alert + daily distilled digest
- canary update and promotion gate
- required smoke checks (gateway, channels, ACP continuity, Playwright/PDF, secrets)
- secret backup/audit/recovery helpers
- weekly hygiene and drift checks

For operator procedures and recovery policy, see `RUNBOOK.md`.
For current-state handoff and parallel execution prompts, see `HANDOFF-2026-04-03.md`.

## Files

- `lib.sh`: shared logging, snapshot, notification, lock, and drift helpers.
- `apply-baseline.sh`: atomically apply baseline pack and write drift lock file.
- `validate-runtime.sh`: validate config, drift state, and required secrets.
- `rollback-baseline.sh`: restore from latest or selected snapshot.
- `release-watch.sh`: detect new `openclaw` releases hourly and trigger canary.
- `daily-release-digest.sh`: send daily workflow-focused digest from changelog.
- `smoke-suite.sh`: sequential validation suite with heavy-work serialization.
- `canary-promote.sh`: dry-run -> canary update -> smoke -> promote gate.
- `secrets-recover.sh`: backup/restore/audit for credentials and required secrets.
- `weekly-hygiene.sh`: recurring drift, auth, release readiness, rollback drill.
- `install-systemd.sh`: install user timers for watcher/digest/hygiene.
- `deploy-remote.sh`: rsync package + systemd units to a remote host.
- `bootstrap.sh`: one-command bootstrap (local or remote) for full setup + validation.
- `RUNBOOK.md`: operational runbook for steady-state, canary, and incident handling.

## Baseline Pack

`baseline/` contains the canonical source of truth:

- `openclaw.json`
- `exec-approvals.json`
- `AGENTS.md`
- `HEARTBEAT.md`
- `env-contract.txt`

Replace placeholders in baseline before applying.

## Quick Start (on host)

1. Apply baseline:

```bash
scripts/ops/clawops/apply-baseline.sh
```

2. Record drift baseline for known override files:

```bash
scripts/ops/clawops/validate-runtime.sh --record-drift-baseline
```

3. Install timers:

```bash
scripts/ops/clawops/install-systemd.sh
```

4. Run one-shot validation + smoke:

```bash
scripts/ops/clawops/validate-runtime.sh
scripts/ops/clawops/smoke-suite.sh
```

5. Or run the full bootstrap workflow:

```bash
scripts/ops/clawops/bootstrap.sh
```

Remote bootstrap:

```bash
scripts/ops/clawops/bootstrap.sh --target user@host --remote-dir /opt/clawops
```

Green bootstrap means:

- `runtime-validate` ends with `ok`
- `smoke-suite` ends with `ok`
- `weekly-hygiene` ends with `ok`
- `release-watch.json` contains non-null canary state after canary run

## Important Environment Variables

- Notification routing:
  - `CLAWOPS_NOTIFY_CHANNEL` (default `telegram`)
  - `CLAWOPS_NOTIFY_TARGET` (required for DM alerts)
  - `CLAWOPS_NOTIFY_ACCOUNT` (optional)

- Pipeline behavior:
  - `CLAWOPS_RUN_CANARY_ON_NEW_RELEASE` (default `1`)
  - `CLAWOPS_PROMOTE_ON_GREEN` (default `0`)
  - `CLAWOPS_PROD_PROMOTE_CMD` (required when auto-promotion enabled)
  - `CLAWOPS_PROD_ROLLBACK_CMD` (required when auto-promotion enabled)
  - `CLAWOPS_PROD_SMOKE_CMD` (optional override)
  - `CLAWOPS_PROMOTION_PAUSE_FILE` (optional; default `$CLAWOPS_STATE_DIR/promotion-paused`)

- Self-heal and reboot guardrail:
  - `CLAWOPS_SELF_HEAL_CMD` (service/gateway/connector restart sequence)
  - `CLAWOPS_ENABLE_REBOOT` (`0`/`1`)
  - `CLAWOPS_REBOOT_CMD` (used only after failed self-heal + failed re-smoke)

- Required secret checks:
  - `CLAWOPS_REQUIRED_SECRETS` (comma-separated)

- Memory pressure controls (4GB hosts):
  - `CLAWOPS_MIN_AVAILABLE_MB` (default `350`)
  - `CLAWOPS_MAX_SWAP_USED_MB` (default `1536`)

- Smoke-run stability controls:
  - `CLAWOPS_SMOKE_TIMEOUT_SEC` (default `45`)
  - `CLAWOPS_BROWSER_SMOKE_URL` (default `https://example.com`)
  - `CLAWOPS_BROWSER_RETRIES` (default `2`)
  - `CLAWOPS_BROWSER_RETRY_DELAY_SEC` (default `5`)
  - `CLAWOPS_BROWSER_SETTLE_SEC` (default `3`)

## Restore Wiped Credentials

If credentials were wiped:

```bash
scripts/ops/clawops/secrets-recover.sh --restore-latest
scripts/ops/clawops/secrets-recover.sh --audit-only
```

This validates Notion/shibot keys when configured in `CLAWOPS_REQUIRED_SECRETS`.

## Program Handoff

Use `HANDOFF-2026-04-03.md` as the canonical context packet for follow-on chats.

It includes:

- validated runtime snapshot
- completed changes from the recovery cycle
- open issues and constraints
- split workstreams and copy/paste prompts for parallel execution
