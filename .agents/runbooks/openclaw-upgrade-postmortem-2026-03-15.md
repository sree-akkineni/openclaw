# OpenClaw Approval UX Postmortem (March 15, 2026)

## Scope
Postmortem for the duplicate Telegram exec approval UI observed on `clawops` after the `2026.3.13` rollout.

## What happened
- Live `clawops` had both generic exec approval forwarding and native Telegram exec approvals enabled:
  - `approvals.exec.enabled=true` with `mode="session"`
  - `channels.telegram.execApprovals.enabled=true` with `target="both"`
- The live runtime contains two Telegram approval delivery systems:
  - the gateway-side generic forwarder
  - the Telegram-native exec approvals handler
- Those two paths subscribe to the same approval request stream. In practice, that can produce duplicate approval messages or buttons for the same approval id.

## Why this was confusing
- The local repo checkout had newer approval fallback code, but the deployed runtime bundle did not match it exactly.
- The live `/approve` parser still required an explicit approval id, so the no-id fallback in the local checkout was not actually available in production.
- Because the live runtime includes a partial suppression guard for Telegram, it was easy to assume duplicate delivery could not happen. That guard depends on accurate turn-source metadata and is not a safe reason to run both approval systems on the same bot.

## Fix applied
- Removed `approvals.exec` from `/opt/clawops/config/openclaw.json`.
- Restarted `clawops-gateway`.
- Re-verified live health and tool behavior.
- Updated `scripts/gateway-verify-upgrade.sh` and the live-state manifest so future drift fails verification.
- Follow-up: deployed hotfix image tags `openclaw:2026.3.13-core-custom-approve-latest1` and `openclaw:2026.3.13-custom-approve-latest1` so the native Telegram runtime also supports the no-id `/approve allow-once|allow-always|deny` fallback.

## Lessons
- Pick one approval UI path per Telegram bot.
- Treat native Telegram `execApprovals` and generic `approvals.exec` as overlapping mechanisms, not additive defaults.
- Do not assume the local checkout exactly matches the deployed runtime bundle when debugging approval UX.
- When verifying the optional Telegram no-id fallback, do not treat generic approval prompt text as proof. Verify the actual `/approve [id] ...` parser or the missing-latest error string in the running bundle.
