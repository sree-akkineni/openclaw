# Stream C: Group + DM + Global Memory Architecture (Obsidian + QMD)

This Stream C design extends `scripts/ops/clawops/HANDOFF-2026-04-03.md` and follows a Karpathy-style memory loop:

1. raw capture (append-only)
2. LLM synthesis (deterministic, auditable outputs)
3. interlinked markdown knowledge notes
4. lint/consistency checks before retrieval

The pilot is markdown-first and file-backed by default (no opaque memory store).

## 1) Architecture Spec

### 1.1 Memory tiers

- `global-shared`
  - long-lived operational facts and cross-team runbook intelligence
  - no user-private details
- `group-shared`
  - memory for one group/thread context key only
  - key form: `<channel>:<groupId>[:<topicId>]`
- `person-private`
  - per-user DM memory only
  - key form: `<channel>:<userId>`

Hard isolation rule: retrieval is tier- and context-key scoped. No cross-tier reads without an explicit carryover artifact.

### 1.2 Cross-surface influence rules

Default behavior is deny-by-default for cross-surface influence:

- `group-shared -> person-private`: denied unless explicit DM consent artifact exists
- `person-private -> group-shared`: denied unless explicit user-approved publish artifact exists
- `group-shared -> global-shared`: denied by default; requires operator-approved promotion
- `person-private -> global-shared`: denied by default; requires explicit user consent and redaction
- same-surface summarize/retrieve (`group->group`, `dm->dm`, `global->global`): allowed

Carryover states:

- `proposed`
- `approved`
- `rejected`
- `expired`

### 1.3 Privacy, consent, and redaction boundaries

Cross-surface carryover requires all of the following:

- explicit `consent_basis` (for example `dm_opt_in`, `group_public_and_acknowledged`, `operator_policy_approved`)
- redaction pass marked complete
- provenance references to source summary/event IDs
- retention window (`ttl_days`, `retention_until`)

Redaction boundaries in pilot policy:

- must remove: email, phone, credentials/secrets, payment-card-like data, long direct quotes
- must mask: person handle, ticket IDs, internal hostnames

### 1.4 Data model (Markdown + QMD)

Summary note frontmatter fields (required in pilot):

- `memory_id`: stable deterministic ID
- `schema_version`: `stream-c-v1`
- `tier`: `global-shared | group-shared | person-private`
- `scope`: `global | group | dm`
- `context_key`: canonical context identifier
- `source.raw_files[]`, `source.event_ids[]`
- `confidence`: 0-1 confidence score
- `ttl_days`, `retention_until`
- `sensitivity[]`
- `links.timeline[]`, `links.concepts[]`

QMD ingest JSON mirrors the same contract and adds `artifact_type`, `provenance`, and flattened retrieval text.

## 2) Obsidian + QMD Pipeline Design

### 2.1 Folder strategy

Root: `scripts/ops/clawops/stream-c/memory/`

- `raw/`
  - `raw/global/**.jsonl`
  - `raw/groups/**.jsonl`
  - `raw/dm/**.jsonl`
- `obsidian-vault/`
  - `global/`
  - `groups/`
  - `dm/`
  - `entities/`
  - `timeline/`
- `qmd/ingest/`
- `carryover/{proposed,approved,rejected,expired}/`
- `lint/`

### 2.2 Compilation/synthesis jobs

Pipeline command: `node scripts/ops/clawops/stream-c/memory-pipeline.mjs compile`

Compile steps:

1. Read raw JSONL files from `raw/`.
2. Build one deterministic summary per `(tier, context_key, day)`.
3. Read approved carryover artifacts from `carryover/approved/*.json` and enforce `state=approved`, explicit `consent_basis`, and `redaction.applied=true`.
4. Extract entities and create/update concept notes in `obsidian-vault/entities/`.
5. Update timeline notes in `obsidian-vault/timeline/YYYY-MM-DD.md`.
6. Emit retrieval records to `qmd/ingest/<memory_id>.json`.

### 2.3 Deterministic naming and linking conventions

- Summary note path:
  - `obsidian-vault/<scope-section>/<context-slug>-<hash8>/<YYYY-MM-DD>--summary.md`
- Concept note path:
  - `obsidian-vault/entities/<entity-slug>-<hash8>.md`
- Timeline note path:
  - `obsidian-vault/timeline/<YYYY-MM-DD>.md`

Internal links use wikilinks to vault-relative paths, for example:

- `[[timeline/2026-04-03]]`
- `[[entities/openclaw-6d1293f6]]`

### 2.4 Lint/validation checks

Lint command: `node scripts/ops/clawops/stream-c/memory-pipeline.mjs lint`

Checks implemented:

- broken wikilinks
- duplicate entity IDs across concept notes
- stale summaries (`retention_until < today`)

Lint report output:

- `memory/lint/latest-report.json`

## 3) Pilot Implementation Patch Set

### 3.1 Files

- `scripts/ops/clawops/stream-c/setup-memory-structure.sh`
- `scripts/ops/clawops/stream-c/memory-pipeline.mjs`
- `scripts/ops/clawops/stream-c/README.md`

### 3.2 Local run commands

```bash
bash scripts/ops/clawops/stream-c/setup-memory-structure.sh
node scripts/ops/clawops/stream-c/memory-pipeline.mjs seed-sample
node scripts/ops/clawops/stream-c/memory-pipeline.mjs seed-carryover-sample
node scripts/ops/clawops/stream-c/memory-pipeline.mjs compile
node scripts/ops/clawops/stream-c/memory-pipeline.mjs lint
node scripts/ops/clawops/stream-c/memory-pipeline.mjs demo
```

### 3.3 Expected sample outputs

The seeded pilot generates at least these 3 summary notes end-to-end:

- one `group-shared` summary note
- one `person-private` summary note
- one `global-shared` summary note

Current seeded examples:

- `memory/obsidian-vault/groups/telegram-100777000111-17-a0c5df77/2026-04-03--summary.md`
- `memory/obsidian-vault/dm/telegram-99887766-74db8f74/2026-04-03--summary.md`
- `memory/obsidian-vault/global/ops-release-intel-5ec31d95/2026-04-03--summary.md`

And supporting artifacts:

- concept/entity notes
- timeline note for the same date
- QMD ingest JSON records in `memory/qmd/ingest/`
- one approved carryover artifact seeded into `memory/carryover/approved/`

### 3.4 Retrieval path demonstration

1. Group memory query:

```bash
node scripts/ops/clawops/stream-c/memory-pipeline.mjs query \
  --tier group-shared \
  --context-key 'telegram:-100777000111:17'
```

2. DM memory query:

```bash
node scripts/ops/clawops/stream-c/memory-pipeline.mjs query \
  --tier person-private \
  --context-key 'telegram:99887766'
```

3. Scoped separation check (group key queried in DM tier should return 0):

```bash
node scripts/ops/clawops/stream-c/memory-pipeline.mjs query \
  --tier person-private \
  --context-key 'telegram:-100777000111:17'
```

Or run all three in one command:

```bash
node scripts/ops/clawops/stream-c/memory-pipeline.mjs demo
```

## 4) Validation and Hardening

### 4.1 Test plan + pass/fail checklist

- `setup-memory-structure.sh` is idempotent on rerun.
- `seed-sample` creates deterministic raw fixtures.
- `compile` creates summary/entity/timeline markdown plus QMD ingest records.
- `compile` rejects invalid carryover artifacts (not approved, missing consent, or redaction not applied).
- `lint` passes with no broken links, duplicates, or stale summaries.
- `demo` returns:
  - `group_query.hit_count >= 1`
  - `dm_query.hit_count >= 1`
  - `scoped_separation_check.pass = true`

### 4.2 Resource profile (pilot target)

- optimized for constrained hosts (single-process local script, file-backed IO)
- no DB daemon required
- incremental ingestion by adding JSONL files under `raw/`
- deterministic outputs for audit and diff review

### 4.3 Failure modes

- malformed JSONL line causes compile failure with file+line reference
- missing raw input leads to explicit compile error
- stale summary TTL trips lint failure
- broken wikilink trips lint failure

### 4.4 Next-step backlog (production hardening)

1. Add policy-file rule evaluation for carryover source/target pair decisions (currently schema-gated only).
2. Add redaction engine beyond policy metadata (regex + classifier hooks).
3. Add incremental compile mode by changed raw file hash.
4. Add signed audit log entries for carryover approvals/rejections.
5. Add policy-aware runtime hook from OpenClaw channel handlers.
6. Add retention sweeper and archival for expired notes/records.
7. Add CI smoke (`setup -> seed -> compile -> lint -> demo`).
