#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ops/clawops/lib.sh
source "$SCRIPT_DIR/lib.sh"

snapshot_id=""
SKIP_VALIDATE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot-id)
      snapshot_id="$2"
      shift 2
      ;;
    --skip-validate)
      SKIP_VALIDATE=1
      shift
      ;;
    *)
      log_line "ERROR unknown argument: $1"
      exit 2
      ;;
  esac
done

init_clawops_layout

if [[ -z "$snapshot_id" ]]; then
  snapshot_id="$(latest_snapshot_id || true)"
fi

if [[ -z "$snapshot_id" ]]; then
  log_line "ERROR no snapshot id provided and no snapshots found"
  exit 1
fi

log_line "restoring snapshot: $snapshot_id"
restore_snapshot "$snapshot_id"
append_event "baseline-rollback" "ok" "snapshot=$snapshot_id"
notify_operator "rollback restored snapshot $snapshot_id"

if (( SKIP_VALIDATE == 0 )); then
  "$SCRIPT_DIR/validate-runtime.sh" --no-strict-secrets || true
fi
