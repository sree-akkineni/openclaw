#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ops/clawops/lib.sh
source "$SCRIPT_DIR/lib.sh"

BACKUP_ONLY=0
RESTORE_LATEST=0
AUDIT_ONLY=0
snapshot_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-only)
      BACKUP_ONLY=1
      shift
      ;;
    --restore-latest)
      RESTORE_LATEST=1
      shift
      ;;
    --audit-only)
      AUDIT_ONLY=1
      shift
      ;;
    --snapshot-id)
      snapshot_id="$2"
      shift 2
      ;;
    *)
      log_line "ERROR unknown argument: $1"
      exit 2
      ;;
  esac
done

init_clawops_layout

if (( BACKUP_ONLY == 1 )); then
  sid="$(create_runtime_snapshot "secrets-backup")"
  log_line "secret snapshot created: $sid"
  append_event "secrets-backup" "ok" "snapshot=$sid"
  exit 0
fi

if (( RESTORE_LATEST == 1 )); then
  if [[ -z "$snapshot_id" ]]; then
    snapshot_id="$(latest_snapshot_id || true)"
  fi
  if [[ -z "$snapshot_id" ]]; then
    log_line "ERROR no snapshot available for restore"
    exit 1
  fi
  restore_snapshot "$snapshot_id"
  log_line "restored snapshot: $snapshot_id"
  append_event "secrets-restore" "ok" "snapshot=$snapshot_id"
fi

missing=0

required_files=(
  "$HOME/.openclaw/credentials"
  "$HOME/.openclaw/agents/main/agent/auth-profiles.json"
)

for f in "${required_files[@]}"; do
  if [[ ! -e "$f" ]]; then
    log_line "ERROR required auth artifact missing: $f"
    missing=1
  else
    log_line "OK auth artifact present: $f"
  fi
done

required_secrets="${CLAWOPS_REQUIRED_SECRETS-NOTION_API_KEY,SHIBOT_NOTION_API_KEY,HIMALAYA_PASSWORD,GMAIL_APP_PASSWORD}"
IFS=',' read -r -a keys <<<"$required_secrets"
for key in "${keys[@]}"; do
  key="${key//[[:space:]]/}"
  [[ -z "$key" ]] && continue

  if [[ -n "${!key:-}" ]]; then
    log_line "OK env secret present: $key"
    continue
  fi
  if [[ -f "$HOME/.openclaw/.env" ]] && grep -q "^${key}=" "$HOME/.openclaw/.env"; then
    log_line "OK .env secret present: $key"
    continue
  fi

  log_line "ERROR secret missing: $key"
  missing=1
done

if command -v openclaw >/dev/null 2>&1; then
  if ! openclaw models status --check >/dev/null 2>&1; then
    log_line "ERROR model auth check failed"
    missing=1
  else
    log_line "OK model auth check"
  fi
else
  log_line "WARN openclaw CLI not found; skipped models status check"
fi

if (( missing == 1 )); then
  append_event "secrets-audit" "error" "missing credentials or secrets"
  notify_operator "secret audit detected missing credentials (including Notion/shibot checks)"
  if (( AUDIT_ONLY == 1 )); then
    exit 1
  fi
  exit 1
fi

append_event "secrets-audit" "ok" "all required secrets present"
log_line "secret audit passed"
