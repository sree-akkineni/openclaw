#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/memory"

log() {
  printf '[stream-c/setup] %s\n' "$*"
}

mk_dir() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    log "exists: ${dir#$SCRIPT_DIR/}"
  else
    mkdir -p "$dir"
    log "created: ${dir#$SCRIPT_DIR/}"
  fi
}

write_if_missing() {
  local path="$1"
  local content="$2"
  if [[ -f "$path" ]]; then
    log "exists: ${path#$SCRIPT_DIR/}"
    return
  fi
  printf '%s\n' "$content" > "$path"
  log "created: ${path#$SCRIPT_DIR/}"
}

mk_dir "$ROOT_DIR"
mk_dir "$ROOT_DIR/raw"
mk_dir "$ROOT_DIR/raw/global"
mk_dir "$ROOT_DIR/raw/groups"
mk_dir "$ROOT_DIR/raw/dm"
mk_dir "$ROOT_DIR/global"
mk_dir "$ROOT_DIR/groups"
mk_dir "$ROOT_DIR/dm"
mk_dir "$ROOT_DIR/carryover"
mk_dir "$ROOT_DIR/carryover/proposed"
mk_dir "$ROOT_DIR/carryover/approved"
mk_dir "$ROOT_DIR/carryover/rejected"
mk_dir "$ROOT_DIR/carryover/expired"
mk_dir "$ROOT_DIR/audit"
mk_dir "$ROOT_DIR/lint"
mk_dir "$ROOT_DIR/obsidian-vault"
mk_dir "$ROOT_DIR/obsidian-vault/global"
mk_dir "$ROOT_DIR/obsidian-vault/groups"
mk_dir "$ROOT_DIR/obsidian-vault/dm"
mk_dir "$ROOT_DIR/obsidian-vault/entities"
mk_dir "$ROOT_DIR/obsidian-vault/timeline"
mk_dir "$ROOT_DIR/qmd"
mk_dir "$ROOT_DIR/qmd/ingest"
mk_dir "$ROOT_DIR/qmd/archive"
mk_dir "$ROOT_DIR/templates"
mk_dir "$ROOT_DIR/examples"

write_if_missing "$ROOT_DIR/raw/global/.gitkeep" ""
write_if_missing "$ROOT_DIR/raw/groups/.gitkeep" ""
write_if_missing "$ROOT_DIR/raw/dm/.gitkeep" ""
write_if_missing "$ROOT_DIR/global/.gitkeep" ""
write_if_missing "$ROOT_DIR/groups/.gitkeep" ""
write_if_missing "$ROOT_DIR/dm/.gitkeep" ""
write_if_missing "$ROOT_DIR/carryover/proposed/.gitkeep" ""
write_if_missing "$ROOT_DIR/carryover/approved/.gitkeep" ""
write_if_missing "$ROOT_DIR/carryover/rejected/.gitkeep" ""
write_if_missing "$ROOT_DIR/carryover/expired/.gitkeep" ""
write_if_missing "$ROOT_DIR/audit/.gitkeep" ""
write_if_missing "$ROOT_DIR/lint/.gitkeep" ""
write_if_missing "$ROOT_DIR/obsidian-vault/global/.gitkeep" ""
write_if_missing "$ROOT_DIR/obsidian-vault/groups/.gitkeep" ""
write_if_missing "$ROOT_DIR/obsidian-vault/dm/.gitkeep" ""
write_if_missing "$ROOT_DIR/obsidian-vault/entities/.gitkeep" ""
write_if_missing "$ROOT_DIR/obsidian-vault/timeline/.gitkeep" ""
write_if_missing "$ROOT_DIR/qmd/ingest/.gitkeep" ""
write_if_missing "$ROOT_DIR/qmd/archive/.gitkeep" ""

write_if_missing "$ROOT_DIR/policy.json" '{
  "version": "2026-04-05",
  "memoryTiers": [
    "global-shared",
    "group-shared",
    "person-private"
  ],
  "default": {
    "crossSurfaceInfluence": "deny",
    "sameSurfaceSummaries": "allow",
    "qmdRawIngest": "deny"
  },
  "states": ["proposed", "approved", "rejected", "expired"],
  "redactionBoundaries": {
    "mustRemove": [
      "email",
      "phone",
      "credentials",
      "payment-card",
      "exact-quote-over-200-chars"
    ],
    "mustMask": [
      "person-handle",
      "ticket-id",
      "internal-hostname"
    ]
  },
  "consentPolicy": {
    "groupToDm": "explicit-opt-in-only",
    "dmToGroup": "explicit-opt-in-only",
    "globalPromotion": "operator-approved-or-public-fact"
  },
  "rules": [
    {
      "id": "global-to-group-default-deny",
      "from": "global-shared",
      "to": "group-shared",
      "allow": false,
      "requireConsentBasis": true,
      "requireRedaction": true
    },
    {
      "id": "global-to-dm-default-deny",
      "from": "global-shared",
      "to": "person-private",
      "allow": false,
      "requireConsentBasis": true,
      "requireRedaction": true
    },
    {
      "id": "group-to-dm-default-deny",
      "from": "group-shared",
      "to": "person-private",
      "allow": false,
      "requireConsentBasis": true,
      "requireRedaction": true
    },
    {
      "id": "dm-to-group-default-deny",
      "from": "person-private",
      "to": "group-shared",
      "allow": false,
      "requireConsentBasis": true,
      "requireRedaction": true
    },
    {
      "id": "group-to-global-review-gate",
      "from": "group-shared",
      "to": "global-shared",
      "allow": false,
      "requireConsentBasis": true,
      "requireRedaction": true
    },
    {
      "id": "dm-to-global-review-gate",
      "from": "person-private",
      "to": "global-shared",
      "allow": false,
      "requireConsentBasis": true,
      "requireRedaction": true
    }
  ]
}'

write_if_missing "$ROOT_DIR/templates/summary-template.md" '---
memory_id: mem-0001
schema_version: stream-c-v1
tier: group-shared
scope: group
context_key: telegram:-1001234567890:42
source:
  raw_files: []
  event_ids: []
confidence: 0.80
ttl_days: 14
retention_until: 2026-04-30
sensitivity: [internal]
created_at: 2026-04-04T00:00:00Z
updated_at: 2026-04-04T00:00:00Z
links:
  timeline: []
  concepts: []
---

# Summary

## Key Points
- 

## Decisions
- 

## Open Questions
- 
'

write_if_missing "$ROOT_DIR/templates/carryover-proposal-template.json" '{
  "artifact_id": "co-0001",
  "source": {
    "domain": "group-shared",
    "context_key": "telegram:group-id"
  },
  "target": {
    "domain": "person-private",
    "context_key": "telegram:user-id"
  },
  "state": "proposed",
  "consent_basis": "required",
  "redaction": {
    "applied": true,
    "labels": ["pii", "secrets"]
  },
  "retention_until": "2026-05-04",
  "provenance": {
    "summary_ids": [],
    "event_range": ""
  },
  "payload": {
    "title": "",
    "bullets": []
  }
}'

write_if_missing "$ROOT_DIR/templates/qmd-ingest-template.json" '{
  "memory_id": "mem-0001",
  "schema_version": "stream-c-v1",
  "domain": "group-shared",
  "scope": "group",
  "context_key": "telegram:group-id",
  "source": {
    "note_path": "",
    "raw_files": []
  },
  "confidence": 0.8,
  "ttl_days": 14,
  "retention_until": "2026-04-30",
  "artifact_type": "summary",
  "sensitivity": ["internal"],
  "provenance": {
    "source_file": "",
    "artifact_id": ""
  },
  "text": ""
}'

write_if_missing "$ROOT_DIR/examples/group-key-example.txt" 'channel:group[:topic]
telegram:-1001234567890:42
slack:T12345:C67890
discord:guild123:thread456
'

write_if_missing "$ROOT_DIR/examples/person-key-example.txt" 'channel:user
telegram:123456789
slack:T12345:U67890
discord:user123
'

write_if_missing "$ROOT_DIR/templates/raw-event-template.jsonl" '{"event_id":"evt-0001","timestamp":"2026-04-03T10:00:00Z","surface":"group","channel":"telegram","context_key":"telegram:-1001234567890:42","actor":"operator","text":"Release smoke passed for canary","entities":["canary","smoke-suite"],"labels":["update"],"confidence":0.85}'

log "stream-c memory structure is ready"
