---
summary: "Fork-only capability index and upstream reconciliation checklist"
read_when:
  - You maintain a fork of OpenClaw and need to track custom behavior
  - You are pulling a new upstream release and want a repeatable sync checklist
title: "Fork Customizations"
---

# Fork Customizations

This page tracks fork-only behavior that is not part of upstream `openclaw/openclaw`.

Last verified: `2026-02-10`  
Reconciliation commit: `dccce70e0` (merged `upstream/main` into `fork/reconcile-2026-02-10`)  
Upstream head at reconciliation: `53273b490`

## Quick status checks

Use these commands to confirm fork status at any time:

```bash
git fetch upstream origin
git rev-list --left-right --count upstream/main...origin/main
git log --oneline upstream/main..origin/main
```

Interpretation:

- Left number = commits only in upstream (pending to pull).
- Right number = commits only in fork (custom layer).

## Current fork-only capabilities

### 1) `x_search` tool (X/Twitter social listening)

- Adds tool: `x_search`
- Purpose: recent X/Twitter search for social listening and research collection
- Config source:
  - `tools.web.x.bearerToken`
  - or `X_BEARER_TOKEN` env
- Security: tool output is wrapped as untrusted external content

Main files:

- `src/agents/tools/x-search.ts`
- `src/agents/tools/web-tools.ts`
- `src/agents/openclaw-tools.ts`
- `src/config/types.tools.ts`
- `src/commands/configure.wizard.ts`
- `src/security/external-content.ts`

### 2) `research_loop` tool (structured research workflow)

- Adds tool: `research_loop`
- Actions: `start`, `checkpoint`, `continue`, `status`, `list`, `close`
- Keeps persistent loop state (rounds, quality signals, citations, recommendations)
- Designed for explicit orchestration and review checkpoints

Main files:

- `src/agents/tools/research-loop-tool.ts`
- `src/agents/research-loop-registry.store.ts`
- `src/agents/openclaw-tools.ts`
- `src/agents/tool-policy.ts`
- `src/agents/sandbox/constants.ts`
- `src/agents/pi-tools.policy.ts`

### 3) Sandbox/tool policy updates for custom tools

- Ensures web/search tooling is available in sandboxed agent sessions
- Keeps `research_loop` denied in subagents by default for controlled delegation

Main files:

- `src/agents/tool-policy.ts`
- `src/agents/pi-tools.policy.ts`
- `src/agents/sandbox/constants.ts`

### 4) Runtime resiliency hardening

- TLS socket guard for Node 22/undici handle race
- Suppresses transient network faults from crashing the process

Main files:

- `src/infra/tls-socket-guard.ts`
- `src/entry.ts`
- `src/index.ts`
- `src/infra/unhandled-rejections.ts`

### 5) Docker image additions for research workflows

- Adds tooling used by fork workflows:
  - `himalaya`
  - `uv`
  - `@steipete/summarize`

Main file:

- `Dockerfile`

## Commit index (custom layer)

As of `2026-02-10`, custom commits on top of upstream:

1. `bc8c47980` feat: add `x_search` tool for X/Twitter search + Perplexity prefix fix
2. `5fae83856` fix: allow web tools in sandboxed agent sessions
3. `e313a82e6` feat: add skill binaries to Dockerfile (himalaya, uv, summarize)
4. `e240aaa5d` fix: correct Himalaya download URL for v1.1.0
5. `e2f54584f` fix: guard TLS socket methods against null handle (undici + Node 22)
6. `af43ecfb3` fix: suppress transient network errors (ENETUNREACH) in uncaughtException handler
7. `12aee70c1` feat: add research loop tooling and reliability coverage
8. `52a0dd493` docs: document research loop tooling and probes
9. `277c327ab` fix: clean reconciliation lint + guard typing

## Upstream reconciliation checklist

When upstream ships a new release:

1. `git fetch upstream origin`
2. `git merge --no-ff upstream/main` (or preferred strategy for your fork policy)
3. Run:
   - `pnpm build`
   - `pnpm check`
   - `pnpm test`
4. Resolve any conflicts in custom files listed above first.
5. Re-run:
   - `git rev-list --left-right --count upstream/main...origin/main`
   - `git log --oneline upstream/main..origin/main`
6. Update this page if capabilities/commit list changed.
