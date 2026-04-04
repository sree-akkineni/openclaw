#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ops/clawops/lib.sh
source "$SCRIPT_DIR/lib.sh"

RESTORE_DRILL="${CLAWOPS_ROLLBACK_DRILL_RESTORE:-0}"

init_clawops_layout

failures=0

if ! "$SCRIPT_DIR/validate-runtime.sh"; then
  failures=1
fi

if ! "$SCRIPT_DIR/secrets-recover.sh" --audit-only; then
  failures=1
fi

if ! "$SCRIPT_DIR/release-watch.sh"; then
  failures=1
fi

if ! "$SCRIPT_DIR/daily-release-digest.sh"; then
  failures=1
fi

snapshot_id="$(create_runtime_snapshot "weekly-hygiene-drill")"
archive="$CLAWOPS_SNAPSHOT_DIR/$snapshot_id.tgz"
if ! tar -tzf "$archive" >/dev/null 2>&1; then
  log_line "ERROR rollback drill archive unreadable: $archive"
  failures=1
else
  log_line "OK rollback drill archive verified: $archive"
fi

if [[ "$RESTORE_DRILL" == "1" ]]; then
  if ! "$SCRIPT_DIR/rollback-baseline.sh" --snapshot-id "$snapshot_id" --skip-validate; then
    failures=1
  fi
fi

if (( failures > 0 )); then
  append_event "weekly-hygiene" "error" "failures=$failures"
  notify_operator "weekly hygiene found failures=$failures"
  exit 1
fi

append_event "weekly-hygiene" "ok" "drift, secrets, release readiness, rollback drill all green"
notify_operator "weekly hygiene completed successfully"
