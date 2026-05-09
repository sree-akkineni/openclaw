# Capability Options (2026-05-07)

This note captures current OpenClaw capabilities worth discussing for the four deployed agents.

Status: recommendations accepted on 2026-05-09. Treat the shortlist below as the current enablement plan unless a later note supersedes it.

## Shortlist

| Capability            | Why It Matters                                                                                                                                                                          | Suggested Agent                  | Default Decision                                                            |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- | --------------------------------------------------------------------------- |
| Active memory scoping | Current OpenClaw supports direct/group/channel eligibility and prompt styles. This is the strongest near-term lever for group chat quality without turning on a heavier memory backend. | gumnut, shibot, remy             | Accepted: keep enabled, tune allowed chat types and prompt style per agent. |
| `memory-lancedb`      | Vector-backed long-term memory with recall/store/forget tools and `ltm` commands. Useful after we define privacy and `ai-brain` boundaries.                                             | shibot first, maybe gumnut later | Accepted: do not enable yet; design data boundaries first.                  |
| Memory wiki           | Obsidian-friendly persistent knowledge vault path. Useful for inspectable memory and the user's Markdown-first preference.                                                              | shibot                           | Accepted: prototype against `ai-brain`/Obsidian rather than broad deploy.   |
| Skill Workshop        | Turns reusable workflows and corrections into workspace skills. Useful for making repeated ops and family/travel workflows durable.                                                     | clawops first, then remy/gumnut  | Accepted: pilot in pending/review mode only.                                |
| Tokenjuice            | Compacts noisy exec/bash results without changing command behavior or exit codes. Useful for ops agents where tool output is verbose.                                                   | clawops                          | Accepted: consider enabling after one controlled smoke.                     |
| Webhooks plugin       | Authenticated inbound hooks can bind external automation to TaskFlows. Useful for release watcher, calendar/task triggers, or `ai-brain` ingestion.                                     | clawops, shibot                  | Accepted: defer until auth/runbook is explicit.                             |
| Lobster               | External task/call delegation workflow. Useful if Remy or Gumnut need human follow-up loops.                                                                                            | remy/gumnut                      | Accepted: defer; Duckbill already covers Gumnut's current delegation need.  |
| Brave/search provider | Alternative search provider. Useful only if Perplexity is insufficient or too expensive/noisy.                                                                                          | shibot/remy                      | Accepted: do not install by default; keep Perplexity for now.               |

## Agent-Specific Discussion Items

### Clawops

- Enable `tokenjuice` if verbose shell output is hurting Telegram readability or session context.
- Keep `plugins.allow` narrow and treat any plugin warning as a release hygiene issue.
- Consider webhooks only for signed release/canary events, not arbitrary remote deploy triggers.
- Keep full clawops smoke behind explicit `--with-clawops-smoke`.

### Shibot

- Best candidate for a durable knowledge stack: `memory-wiki`, `memory-lancedb`, and eventual `ai-brain` bridge.
- Keep stale search/memory plugins removed until we intentionally choose them.
- Discuss whether `memory-lancedb` should use OpenAI API-key embeddings, GitHub Copilot embeddings, or local/Ollama embeddings.
- Add a research brief template with source attribution before enabling auto-capture.

### Gumnut

- Keep current plugin posture: Telegram/Slack, OpenAI, browser, active-memory, Perplexity, Duckbill.
- Tune active memory toward `preference-only` and carefully review group-vs-DM behavior for family privacy.
- Consider daily family brief and newborn admin playbooks before adding new plugins.
- Avoid broader memory backends until carryover/privacy rules are tested.

### Remy

- Keep browser and Perplexity for travel/event lookups.
- Consider Skill Workshop for repeatable trip dossier and venue shortlist workflows.
- Consider Lobster only if Remy needs delegated human follow-up distinct from Duckbill.
- Add external-share safety mode before exposing to others.

## Current Non-Decisions

- Do not enable `memory-lancedb` just because it is available. It needs a source-of-truth and privacy policy first.
- Do not install Brave just to clear old config warnings. The stale entry has been removed.
- Do not run production deploys from Codex Cloud.
- Do not broaden plugin allowlists to silence friction; keep explicit allowlists and add capabilities deliberately.
