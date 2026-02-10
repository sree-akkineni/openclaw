---
summary: "One person workflow for agent evals with a main agent plus two helper agents"
read_when:
  - You are running evals alone and need a repeatable operating model
  - You want helper agents for quality review and workflow improvement
  - You want to use OpenAI Codex auth with `openai-codex/gpt-5.3-codex`
title: "Solo Evals with Helper Agents"
---

# Solo evals with helper agents

This runbook is for a one person team.
It keeps you fast without losing quality by using one delivery agent and two helper agents.

## Operating model

- `main`: builds and ships.
- `eval-engineer`: reviews outputs, scores quality, flags risk.
- `workflow-engineer`: proposes process and prompt changes.
- Human gate at every checkpoint: helper agents advise, you decide.
- Quality first: triage `needs_review` before new work.

## Prerequisites

1. Use Node 22+ (`node -v`).
2. Authenticate Codex:

```bash
openclaw onboard --auth-choice openai-codex
# or
openclaw models auth login --provider openai-codex
```

3. Confirm the model is available:

```bash
openclaw models list | rg openai-codex/gpt-5.3-codex
```

## Baseline config

Add this to `~/.openclaw/openclaw.json` and adjust paths as needed:

```json5
{
  agents: {
    defaults: {
      model: { primary: "openai-codex/gpt-5.3-codex" },
      subagents: {
        model: { primary: "openai-codex/gpt-5.3-codex" },
        maxConcurrent: 2,
        archiveAfterMinutes: 120,
      },
    },
    list: [
      {
        id: "main",
        default: true,
        subagents: { allowAgents: ["eval-engineer", "workflow-engineer"] },
      },
      {
        id: "eval-engineer",
        model: { primary: "openai-codex/gpt-5.3-codex" },
        tools: {
          profile: "coding",
          allow: ["read", "sessions_list", "sessions_history", "session_status", "research_loop"],
          deny: ["write", "edit", "apply_patch", "exec", "process", "sessions_spawn"],
        },
      },
      {
        id: "workflow-engineer",
        model: { primary: "openai-codex/gpt-5.3-codex" },
        tools: {
          profile: "coding",
          allow: ["read", "sessions_list", "sessions_history", "session_status", "research_loop"],
          deny: ["write", "edit", "apply_patch", "exec", "process", "sessions_spawn"],
        },
      },
    ],
  },
}
```

## Weekly cadence for one person

1. Monday planning (30 min)
   - Pick 3 to 5 critical workflows.
   - Define pass criteria per workflow: quality, latency, and failure tolerance.
2. Daily execution (20 to 30 min)
   - Run real tasks with `main`.
   - Save a checkpoint with `research_loop action=checkpoint`.
   - Route low quality items to `needs_review`.
3. Friday review (60 to 90 min)
   - `research_loop action=list view=needs_review`.
   - Spawn helper reviews for only top risk loops.
   - Approve one process change at a time.

## Helper agent task templates

Use these with `sessions_spawn` from the `main` agent.

### Eval reviewer template

```text
agentId: eval-engineer
label: eval-loop-<loopId>
task:
Review research loop <loopId>.
Return Eval Triage Report v1:
- Decision: pass | pass_with_warnings | fail
- QualityScore: 0-100
- EvidenceScore: 0-100
- Top 3 failure risks
- Missing evidence and counterpoints
- One concrete next test
```

### Workflow reviewer template

```text
agentId: workflow-engineer
label: workflow-loop-<loopId>
task:
Given loop <loopId> and eval findings, return Workflow Change Proposal v1:
- Root cause category: prompt | tooling | process | data
- Proposed change: one small change only
- Expected impact metric
- Rollback trigger
- Owner: main (human approved)
```

## Research loop triage policy

- `needs_review`: stop and review before continuing.
- `hot`: highest urgency and impact first.
- `stale`: close or continue, do not leave undecided.
- Never auto-spawn from checkpoint signals. `spawnAdvice` is advisory only.

## Common failure patterns and prevention

- Wrong test suite (`pnpm test` vs `pnpm test:live`):
  - Keep live checks explicit and env-gated.
- Node runtime mismatch:
  - Reject eval data from Node < 22.
- Env set too late for path-cached modules:
  - Export state env vars before imports and test startup.
- Treating `loops.json` as an event log:
  - It is latest state only, not immutable history.
- Changing multiple variables in one eval round:
  - Change one variable per round for clear attribution.

## Acceptance checklist for each weekly cycle

- At least 3 high value workflows evaluated.
- Each workflow has a checkpoint with explicit recommendation and evidence.
- `needs_review` queue is below 5 open loops.
- One approved workflow change is deployed and observed.
- One rollback rule is documented for the new change.

## Related docs

- [Testing](/testing)
- [Sub-agents](/tools/subagents)
- [OpenAI provider setup](/providers/openai)
- [Gateway configuration](/gateway/configuration)
