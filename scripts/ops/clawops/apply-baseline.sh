#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ops/clawops/lib.sh
source "$SCRIPT_DIR/lib.sh"

BASELINE_DIR="${CLAWOPS_BASELINE_DIR:-$SCRIPT_DIR/baseline}"
TARGET_ROOT="${CLAWOPS_TARGET_ROOT:-$HOME/.openclaw}"
DRY_RUN=0
SKIP_VALIDATE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline-dir)
      BASELINE_DIR="$2"
      shift 2
      ;;
    --target-root)
      TARGET_ROOT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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
require_cmd tar

if [[ ! -d "$BASELINE_DIR" ]]; then
  log_line "ERROR baseline directory not found: $BASELINE_DIR"
  exit 1
fi

if (( DRY_RUN == 0 )); then
  if snapshot_id="$(create_runtime_snapshot "pre-baseline-apply" 2>/dev/null)"; then
    log_line "snapshot created: $snapshot_id"
  else
    log_line "WARN snapshot skipped (no existing runtime artifacts yet)"
  fi
else
  log_line "dry-run enabled: snapshot skipped"
fi

copy_file() {
  local src="$1"
  local dst="$2"
  local mode="$3"

  if [[ ! -f "$src" ]]; then
    log_line "ERROR missing baseline file: $src"
    exit 1
  fi

  log_line "apply $src -> $dst"
  if (( DRY_RUN == 1 )); then
    return 0
  fi

  mkdir -p "$(dirname "$dst")"
  install -m "$mode" "$src" "$dst"
}

copy_file "$BASELINE_DIR/openclaw.json" "$TARGET_ROOT/openclaw.json" 600
copy_file "$BASELINE_DIR/exec-approvals.json" "$TARGET_ROOT/exec-approvals.json" 600
copy_file "$BASELINE_DIR/AGENTS.md" "$TARGET_ROOT/workspace/AGENTS.md" 600
copy_file "$BASELINE_DIR/HEARTBEAT.md" "$TARGET_ROOT/workspace/HEARTBEAT.md" 600
copy_file "$BASELINE_DIR/env-contract.txt" "$CLAWOPS_STATE_DIR/env-contract.txt" 600

if [[ -n "${CLAWOPS_BASELINE_EXTRA_MAP:-}" ]]; then
  IFS=';' read -r -a pairs <<<"$CLAWOPS_BASELINE_EXTRA_MAP"
  for pair in "${pairs[@]}"; do
    [[ -z "$pair" ]] && continue
    src_rel="${pair%%:*}"
    dst_abs="${pair#*:}"
    if [[ -z "$src_rel" || -z "$dst_abs" || "$src_rel" == "$dst_abs" ]]; then
      log_line "ERROR invalid CLAWOPS_BASELINE_EXTRA_MAP entry: $pair"
      exit 1
    fi
    copy_file "$BASELINE_DIR/$src_rel" "$dst_abs" 600
  done
fi

if (( DRY_RUN == 0 )); then
  baseline_lock_write "$CLAWOPS_LOCKFILE" \
    "$TARGET_ROOT/openclaw.json" \
    "$TARGET_ROOT/exec-approvals.json" \
    "$TARGET_ROOT/workspace/AGENTS.md" \
    "$TARGET_ROOT/workspace/HEARTBEAT.md" \
    "$CLAWOPS_STATE_DIR/env-contract.txt"
  append_event "baseline-apply" "ok" "target=$TARGET_ROOT baseline=$BASELINE_DIR"
  notify_operator "baseline applied successfully"
else
  append_event "baseline-apply" "dry-run" "target=$TARGET_ROOT baseline=$BASELINE_DIR"
fi

if (( DRY_RUN == 0 && SKIP_VALIDATE == 0 )); then
  "$SCRIPT_DIR/validate-runtime.sh"
fi
