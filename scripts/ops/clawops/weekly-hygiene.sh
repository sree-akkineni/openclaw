#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ops/clawops/lib.sh
source "$SCRIPT_DIR/lib.sh"

RESTORE_DRILL="${CLAWOPS_ROLLBACK_DRILL_RESTORE:-0}"

init_clawops_layout

failures=0
validation_status="ok"
secrets_status="ok"
release_watch_status="ok"
digest_status="ok"
rollback_drill_status="ok"
integration_status="ok"

if ! "$SCRIPT_DIR/validate-runtime.sh"; then
  failures=1
  validation_status="error"
fi

if ! "$SCRIPT_DIR/secrets-recover.sh" --audit-only; then
  failures=1
  secrets_status="error"
fi

if ! "$SCRIPT_DIR/release-watch.sh"; then
  failures=1
  release_watch_status="error"
fi

if ! "$SCRIPT_DIR/daily-release-digest.sh"; then
  failures=1
  digest_status="error"
fi

if ! "$SCRIPT_DIR/integration-suite.sh" --target weekly; then
  failures=1
  integration_status="error"
fi

if snapshot_id="$(create_runtime_snapshot "weekly-hygiene-drill" 2>/dev/null)"; then
  archive="$CLAWOPS_SNAPSHOT_DIR/$snapshot_id.tgz"
  if ! tar -tzf "$archive" >/dev/null 2>&1; then
    log_line "ERROR rollback drill archive unreadable: $archive"
    failures=1
    rollback_drill_status="error"
  else
    log_line "OK rollback drill archive verified: $archive"
  fi
else
  log_line "ERROR rollback drill snapshot creation failed"
  failures=1
  rollback_drill_status="error"
fi

if [[ "$RESTORE_DRILL" == "1" ]]; then
  if ! "$SCRIPT_DIR/rollback-baseline.sh" --snapshot-id "${snapshot_id:-}" --skip-validate; then
    failures=1
    rollback_drill_status="error"
  fi
fi

summary="runtime=$validation_status secrets=$secrets_status release_watch=$release_watch_status digest=$digest_status integration=$integration_status rollback_drill=$rollback_drill_status"
if (( failures > 0 )); then
  append_event "weekly-hygiene" "error" "failures=$failures $summary"
  notify_operator "weekly hygiene failures=$failures | $summary"
  exit 1
fi

append_event "weekly-hygiene" "ok" "$summary"
notify_operator "weekly hygiene completed successfully | $summary"
