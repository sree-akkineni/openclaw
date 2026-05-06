# Agent Capability Roadmap

## Cross-Agent Platform

Highest-value platform work:

- Docker-native release canary and promotion automation using image tags.
- Target-container smoke execution to avoid host-IP hairpin timeouts.
- Explicit plugin allowlists per agent.
- Telegram response formatting policy: table-to-bullets, concise sections, and channel-specific Markdown escaping.
- Memory architecture hardening: group vs DM boundaries, explicit carryover, Obsidian/QMD sync.
- Browser profile lifecycle policy: per-agent profile names, restart persistence, cleanup cadence.
- Integration checks as required gates, not optional skips.

## Clawops

Role: operations/control-plane agent.

Keep enabled:

- Telegram control channel.
- Browser and PDF smoke tooling.
- ACP/control-plane integration.
- File-transfer and device-pair only if operationally needed.

Improve next:

- Docker-image canary automation wired to release watcher.
- In-channel approval policy with narrow allowlists.
- Weekly hygiene report that includes plugin drift, stale config, release status, backup inventory, and failed canary notes.
- Security posture: resolve `tools.fs.workspaceOnly=false` or document why it is required.

## Shibot

Role: personal knowledge and research assistant, eventual bridge to `ai-brain`.

Keep enabled:

- Telegram, Slack if actively used.
- OpenAI native models.
- Browser for research verification.
- Perplexity or a maintained web-search provider.
- Memory/QMD path once `ai-brain` integration is ready.

Reassess:

- Stale `whatsapp`, `lobster`, `memory-lancedb`, and `brave` plugin entries. Either install official external plugins or remove config entries.
- Whether direct Notion/GitHub/Drive integrations should live in Shibot or be delegated to Codex/cloud workflows.

Potential projects:

- `ai-brain` ingestion bridge with explicit source attribution.
- Research brief template that stores durable Markdown notes.
- Telegram formatting layer for cleaner summaries and citations.
- Scheduled research digests with approval-before-send.

## Gumnut

Role: family/life admin assistant for the user, spouse, and newborn routines.

Keep enabled:

- Telegram and Slack if both are actually used.
- Duckbill for task/call delegation.
- Browser for life-admin web lookups.
- Himalaya/Gmail for controlled email workflows.
- Active memory, but with privacy boundaries and explicit carryover.

Improve next:

- Family admin playbooks: newborn appointments, feeding/sleep notes, insurance/forms, household reminders.
- Calendar/task connector decision: prefer one canonical task/calendar system rather than multiple partial stores.
- Duckbill OAuth/token health check in weekly hygiene.
- DM vs group memory policy so family group context does not leak into unrelated sessions.

Potential projects:

- Daily family brief.
- Newborn appointment/document checklist.
- Household vendor/task tracker.
- Email-to-task triage with approval gates.

## Remy

Role: travel/events/rendezvous assistant and prototype for eventual sharing.

Keep enabled:

- Telegram/Slack channels used for coordination.
- Browser for travel/event lookup.
- Himalaya/Gmail if email coordination is part of the flow.
- Maps/places provider if configured and actively useful.

Improve next:

- Travel itinerary object model in Markdown.
- Event/rendezvous planning templates.
- Location-aware suggestions with source links.
- External-share safety mode before exposing to others.

Potential projects:

- Trip dossier generator.
- Venue shortlist workflow with constraints and tradeoffs.
- RSVP/follow-up assistant.
- Shared prototype mode with limited tools and no private memory bleed.

## Capability Decisions

Current defaults that make sense:

- Native `openai/gpt-5.4` primary with `openai/gpt-5.2` fallback for all four agents.
- Gumnut's narrow plugin allowlist model.
- Docker image pinning instead of mutable in-container updates.
- Canary on clawops before any other rollout.

Defaults to change:

- Broad plugin enablement on clawops/remy/shibot.
- Target smoke over host Tailscale IP from inside containers.
- Treating health CLI event-loop warnings during heavy probes as a hard failure without functional corroboration.
