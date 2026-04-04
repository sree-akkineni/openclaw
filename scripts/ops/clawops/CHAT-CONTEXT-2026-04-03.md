# Chat Context Snapshot (2026-04-03)

This file captures key decisions and outcomes from the operator chat so work can resume on another device without replaying thread history.

## Decisions Locked In

- Keep no-GitOps/no-SOPS approach for this phase.
- Run clawops in admin-capable mode with guardrails:
  - self-heal first
  - reboot only after staged recovery fails
  - destructive/mass actions require explicit escalation note.
- Default release policy is canary-first with manual promotion (`CLAWOPS_PROMOTE_ON_GREEN=0`).
- Use daily + immediate release intelligence digests to operator DM.
- Preserve ACP continuity as a core requirement (persistent binding direction).
- Continue reliability-first controls even after droplet memory increase (8GB now).

## Executed Outcomes in This Cycle

- Fleet upgraded and validated on `OpenClaw 2026.4.1`.
- Config-schema drift post-upgrade repaired via doctor migration flow.
- Integrations revalidated (channels, Playwright/PDF, Notion checks).
- Duckbill MCP repaired and runtime-validated on gumnut.
- Clawops script package added with:
  - baseline apply/rollback
  - release watch + digest + canary promotion flow
  - smoke suite
  - weekly hygiene
  - deploy/bootstrap helpers
  - systemd timer units.

## Open Questions / Deferred Work

- WhatsApp for shibot:
  - Built-in OpenClaw WhatsApp is Web/Baileys and requires a real WhatsApp account link.
  - Twilio number provisioning does not replace the built-in QR link flow.
  - Digital-only phone ingress should use Twilio voice/SMS surfaces (or a future Twilio WhatsApp API adapter if desired).
- Group memory design for large group chats:
  - retain shared group memory
  - retain per-person DM memory
  - define safe cross-context promotion rules.
- Evaluate Obsidian + QMD (Tobi) as extended memory systems.

## Next-Chat Execution Priority

- Primary streams requested:
  - ACP persistent binding
  - in-channel approvals
  - cron/webhook orchestration
  - release intelligence pipeline
  - browser profile reuse
  - PDF policy hardening
  - resource guardrails
  - weekly hygiene automation.
- Secondary design stream:
  - group/DM memory architecture + Obsidian/QMD integration path.

## Canonical Companion Files

- `scripts/ops/clawops/HANDOFF-2026-04-03.md`
- `scripts/ops/clawops/RUNBOOK.md`
- `scripts/ops/clawops/README.md`
