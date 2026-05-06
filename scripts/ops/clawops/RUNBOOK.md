# Clawops Reliability Runbook

This runbook covers baseline operations for clawops autonomous ops on a single gateway host.

Companion docs:

- `README.md` for package scope and env variable reference.
- `HANDOFF-2026-04-03.md` for latest recovery snapshot and parallel workstream prompts.
- `channel-strategy.md` for Shibot channel default and fallback runbook.
- `stream-c/README.md` for group-vs-DM memory architecture plan.

## Scope

- Runtime source of truth: `openclaw.json`, `exec-approvals.json`, timer units, and env contract.
- Release flow: detect -> alert -> canary -> smoke -> optional promote.
- Guardrail model: self-heal before reboot, no default auto-promotion.

## Preconditions

- Host has Docker and systemd user services available.
- User can run Docker commands with passwordless sudo (`sudo -n docker ...`).
- `/opt/clawops/.env` contains required routing and secret policy values.
- Baseline files in `scripts/ops/clawops/baseline/` are updated for your environment.

## One-Time Bootstrap

Local on host:

```bash
scripts/ops/clawops/bootstrap.sh
```

Remote from operator workstation:

```bash
scripts/ops/clawops/bootstrap.sh --target user@host --remote-dir /opt/clawops
```

Bootstrap executes, in order:

1. Apply baseline pack.
2. Record drift baseline.
3. Validate runtime and secrets policy.
4. Install and enable timers.
5. Run release-watch one-shot.
6. Run smoke suite.
7. Run weekly hygiene one-shot.

## Daily Operations

Manual status checks:

```bash
systemctl --user list-timers --all | rg 'clawops-(release-watch|daily-digest|weekly-hygiene)'
sudo -n docker exec clawops-gateway sh -lc 'openclaw --version'
sudo -n docker exec clawops-gateway sh -lc 'openclaw gateway status --require-rpc'
sudo -n docker exec clawops-gateway sh -lc 'tail -n 80 $HOME/.openclaw/clawops/logs/operator-digest.jsonl'
sudo -n docker exec clawops-gateway sh -lc 'cat $HOME/.openclaw/clawops/state/release-watch.json'
```

Expected healthy signals:

- Timer units are enabled and have a recent `LAST` run.
- `gateway status --require-rpc` reports `RPC probe: ok`.
- `operator-digest.jsonl` shows recent `smoke-suite ok` and `runtime-validate ok`.
- `release-watch.json` has `lastCanaryStatus: "ok"` after canary.

## Canary Upgrade Procedure

Run controlled canary:

```bash
sudo -n docker exec clawops-gateway sh -lc 'set -a; [ -f /opt/clawops/.env ] && . /opt/clawops/.env; set +a; /opt/clawops/scripts/canary-promote.sh'
```

Acceptance:

- `canary-preflight` is `ok`.
- `canary-update-dry-run` is `ok`.
- `canary-update-apply` is `ok`.
- `smoke-suite` is `ok`.
- `integration-suite` is `ok` for each configured smoke target.
- `canary-pipeline` is `ok`.
- `release-watch.json` has:
  - `lastCanaryVersion` set to target version.
  - `lastCanaryStatus: "ok"`.

Forced-failure rollback and promotion pause validation:

```bash
sudo -n docker exec clawops-gateway sh -lc 'set -a; [ -f /opt/clawops/.env ] && . /opt/clawops/.env; set +a; \
  CLAWOPS_PROMOTE_ON_GREEN=1 \
  CLAWOPS_PROD_PROMOTE_CMD="echo promote-ok" \
  CLAWOPS_PROD_SMOKE_CMD="false" \
  CLAWOPS_PROD_ROLLBACK_CMD="echo rollback-ok" \
  /opt/clawops/scripts/canary-promote.sh || true; \
  cat "$HOME/.openclaw/clawops/state/release-watch.json"; \
  test -f "$HOME/.openclaw/clawops/state/promotion-paused" && echo pause-file-present'
```

## Incident Ladder (Self-Heal Before Reboot)

When smoke or runtime validation fails:

1. Validate current state:
   - `validate-runtime.sh`
   - `smoke-suite.sh`
2. Restore secrets if needed:
   - `secrets-recover.sh --restore-latest`
   - `secrets-recover.sh --audit-only`
3. Roll back baseline if config drift/regression:
   - `rollback-baseline.sh --snapshot-id <id>`
4. Re-run smoke suite.
5. Reboot only after staged recovery still fails and reboot guardrails are enabled.

## Known Failure Signatures

- `npm ERR! code EEXIST` on `/usr/local/bin/openclaw` during `openclaw update --yes`.
  - Mitigation: use fallback apply command in env:
    - `CLAWOPS_CANARY_UPDATE_APPLY_CMD='openclaw update --yes || npm i -g --force openclaw@latest'`
- `WARN lock busy: heavy-smoke`
  - Another smoke run is in progress; do not start a parallel heavy check.
- Gateway handshake timeout during restart window
  - Wait for gateway readiness, then rerun smoke suite.
- WhatsApp/Twilio mismatch assumptions
  - Built-in WhatsApp channel is Web/Baileys linking (QR) and is separate from Twilio-managed phone/SMS/voice surfaces.
  - Do not treat Twilio number provisioning as a replacement for WhatsApp Web linking in current built-in channel flow.

## Secrets and Integrations Verification

Audit only:

```bash
sudo -n docker exec clawops-gateway sh -lc 'set -a; [ -f /opt/clawops/.env ] && . /opt/clawops/.env; set +a; /opt/clawops/scripts/secrets-recover.sh --audit-only'
```

Required secret policy is controlled by:

- `CLAWOPS_REQUIRED_SECRETS` in `/opt/clawops/.env`

Include integration-critical keys (example):

- `NOTION_API_KEY`
- `SHIBOT_NOTION_API_KEY`
- `HIMALAYA_PASSWORD`
- `GMAIL_APP_PASSWORD`

Integration harness one-shot:

```bash
sudo -n docker exec clawops-gateway sh -lc 'set -a; [ -f /opt/clawops/.env ] && . /opt/clawops/.env; set +a; /opt/clawops/scripts/integration-suite.sh --target manual'
```

Recommended `.env` additions:

- `CLAWOPS_INTEGRATION_CHECKS_FILE=/opt/clawops/config/integration-checks.txt`
- `CLAWOPS_INTEGRATION_REQUIRE_CHECKS=1`

Checks file contract:

- One check per line: `scope|name|command`
- Example scopes: `mcp`, `api`, `function`
- `weekly-hygiene.sh` and `smoke-suite.sh` both execute this harness

## Webhook Trigger Mode

Webhook/manual release trigger:

```bash
sudo -n docker exec clawops-gateway sh -lc 'set -a; [ -f /opt/clawops/.env ] && . /opt/clawops/.env; set +a; /opt/clawops/scripts/release-watch-trigger.sh --version 2026.4.1'
```

Webhook with payload file:

```bash
sudo -n docker exec clawops-gateway sh -lc 'set -a; [ -f /opt/clawops/.env ] && . /opt/clawops/.env; set +a; /opt/clawops/scripts/release-watch-trigger.sh --payload-file /tmp/release-event.json --force-canary'
```

Cron session targeting (optional):

- Set `CLAWOPS_NOTIFY_MODE=session`
- Set `CLAWOPS_NOTIFY_AGENT_ID` and `CLAWOPS_NOTIFY_SESSION_KEY`
- Keep `CLAWOPS_NOTIFY_TARGET` configured for fallback DM delivery if session messaging fails

## Multi-container Browser/PDF Smoke Matrix

Run one suite across local + container targets (configured via `CLAWOPS_TARGET_<NAME>_*` env keys):

```bash
sudo -n docker exec clawops-gateway sh -lc 'set -a; [ -f /opt/clawops/.env ] && . /opt/clawops/.env; set +a; CLAWOPS_SMOKE_TARGETS=clawops,remy,gumnut,shibot /opt/clawops/scripts/smoke-suite.sh'
```

## Promotion Policy

Recommended default:

- `CLAWOPS_PROMOTE_ON_GREEN=0` (manual promotion gate).

If enabling auto-promotion:

- Set `CLAWOPS_PROD_PROMOTE_CMD`, `CLAWOPS_PROD_SMOKE_CMD`, and `CLAWOPS_PROD_ROLLBACK_CMD`.
- If production smoke fails after promote, rollback runs and promotion is paused via `promotion-paused` state file.
- Keep rollback snapshot flow enabled.
- Require operator digest review for each promote event.

## Docker Image Upgrade Flow

For compose-managed droplet agents, prefer image-tag rollout over `openclaw update` inside the container:

```bash
scripts/ops/clawops/docker-image-rollout.sh \
  --remote openclaw-droplet \
  --version <version> \
  --rollback-version <previous-version> \
  --targets clawops,shibot,gumnut,remy
```

Use the `openclaw-droplet` SSH alias through Twingate. Current caveat: use clawops local smoke as the canary gate. The older multi-target URL mode can false-negative from container network hairpin timeouts. See `UPGRADE-NOTES-2026-05-06.md`.
