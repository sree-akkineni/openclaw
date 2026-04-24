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
- `release-watch-trigger.sh`: webhook/manual release trigger wrapper for `release-watch.sh`.
- `daily-release-digest.sh`: send daily workflow-focused digest from changelog.
- `smoke-suite.sh`: sequential validation suite with heavy-work serialization.
- `integration-suite.sh`: MCP/API/function integration harness used by smoke + weekly hygiene.
- `canary-promote.sh`: dry-run -> canary update -> smoke -> promote gate.
- `secrets-recover.sh`: backup/restore/audit for credentials and required secrets.
- `weekly-hygiene.sh`: recurring drift, auth, release readiness, rollback drill.
- `validate-whatsapp-channel.sh`: channel validation helper for Twilio voice/SMS or WhatsApp Web mode.
- `install-systemd.sh`: install user timers for watcher/digest/hygiene.
- `deploy-remote.sh`: rsync package + systemd units to a remote host.
- `bootstrap.sh`: one-command bootstrap (local or remote) for full setup + validation.
- `channel-strategy.md`: Stream D comparison and production recommendation (Twilio default, WhatsApp fallback).
- `stream-c/README.md`: Stream C architecture spec and phased implementation plan.
- `stream-c/setup-memory-structure.sh`: scaffold the Stream C memory/policy layout.
- `stream-c/memory-pipeline.mjs`: local Stream C raw->summary->QMD compile/lint/query pipeline.
- `RUNBOOK.md`: operational runbook for steady-state, canary, and incident handling.
- `baseline/integration-checks.txt`: template contract for integration check entries.

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
  - `CLAWOPS_NOTIFY_MODE` (`message` or `session`; `session` enables cron session targeting)
  - `CLAWOPS_NOTIFY_AGENT_ID` (session-targeted agent ID)
  - `CLAWOPS_NOTIFY_SESSION_KEY` (session key for cron-driven notifications)

- Pipeline behavior:
  - `CLAWOPS_RUN_CANARY_ON_NEW_RELEASE` (default `1`)
  - `CLAWOPS_RELEASE_TRIGGER_MODE` (`poll` or `webhook`)
  - `CLAWOPS_RELEASE_WEBHOOK_VERSION` (optional forced version when webhook-triggered)
  - `CLAWOPS_WEBHOOK_FORCE_CANARY` (`1` to rerun canary even when version is unchanged)
  - `CLAWOPS_PROMOTE_ON_GREEN` (default `0`)
  - `CLAWOPS_PROD_PROMOTE_CMD` (required when auto-promotion enabled)
  - `CLAWOPS_PROD_ROLLBACK_CMD` (required when auto-promotion enabled)
  - `CLAWOPS_PROD_SMOKE_CMD` (optional override)
  - `CLAWOPS_PROMOTION_PAUSE_FILE` (optional; default `$CLAWOPS_STATE_DIR/promotion-paused`)
  - `CLAWOPS_CANARY_PREFLIGHT_ENABLED` (default `1`; runs `validate-runtime.sh` before apply)
  - `CLAWOPS_CANARY_PREFLIGHT_CMD` (optional preflight override command)
  - `CLAWOPS_WEBHOOK_URL` (optional event webhook sink)
  - `CLAWOPS_WEBHOOK_TOKEN` (optional bearer token for webhook sink)

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
  - `CLAWOPS_SMOKE_TARGETS` (comma list; default `local`, supports multi-container matrix)
  - `CLAWOPS_BROWSER_SMOKE_URL` (default `https://example.com`)
  - `CLAWOPS_BROWSER_RETRIES` (default `2`)
  - `CLAWOPS_BROWSER_RETRY_DELAY_SEC` (default `5`)
  - `CLAWOPS_BROWSER_SETTLE_SEC` (default `3`)
  - `CLAWOPS_PDF_RETRIES`, `CLAWOPS_PDF_RETRY_DELAY_SEC`, `CLAWOPS_PDF_SETTLE_SEC`, `CLAWOPS_PDF_PASSES`
  - `CLAWOPS_TARGET_<NAME>_URL`, `CLAWOPS_TARGET_<NAME>_TOKEN`, `CLAWOPS_TARGET_<NAME>_BROWSER_PROFILE`
  - `CLAWOPS_INTEGRATION_CHECKS_FILE` (path to `scope|name|command` checks file)
  - `CLAWOPS_INTEGRATION_REQUIRE_CHECKS` (`1` to fail smoke/hygiene when no integration checks are configured)
  - `CLAWOPS_INTEGRATION_TIMEOUT_SEC`, `CLAWOPS_INTEGRATION_RETRIES`, `CLAWOPS_INTEGRATION_RETRY_DELAY_SEC`

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
