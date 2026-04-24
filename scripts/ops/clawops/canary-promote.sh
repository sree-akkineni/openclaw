#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ops/clawops/lib.sh
source "$SCRIPT_DIR/lib.sh"

CANARY_DRY_RUN_CMD="${CLAWOPS_CANARY_UPDATE_DRY_RUN_CMD:-openclaw update --dry-run}"
CANARY_APPLY_CMD="${CLAWOPS_CANARY_UPDATE_APPLY_CMD:-openclaw update --yes}"
CANARY_ROLLBACK_CMD="${CLAWOPS_CANARY_ROLLBACK_CMD:-}"
CANARY_PREFLIGHT_ENABLED="${CLAWOPS_CANARY_PREFLIGHT_ENABLED:-1}"
CANARY_PREFLIGHT_CMD="${CLAWOPS_CANARY_PREFLIGHT_CMD:-$SCRIPT_DIR/validate-runtime.sh}"
PROMOTE_ON_GREEN="${CLAWOPS_PROMOTE_ON_GREEN:-0}"
PROD_PROMOTE_CMD="${CLAWOPS_PROD_PROMOTE_CMD:-}"
PROD_ROLLBACK_CMD="${CLAWOPS_PROD_ROLLBACK_CMD:-}"
PROD_SMOKE_CMD="${CLAWOPS_PROD_SMOKE_CMD:-$SCRIPT_DIR/smoke-suite.sh}"
SELF_HEAL_CMD="${CLAWOPS_SELF_HEAL_CMD:-}"
REBOOT_CMD="${CLAWOPS_REBOOT_CMD:-}"
ENABLE_REBOOT="${CLAWOPS_ENABLE_REBOOT:-0}"
STATE_FILE="$(release_watch_state_file)"
PROMOTION_PAUSE_FILE="${CLAWOPS_PROMOTION_PAUSE_FILE:-$CLAWOPS_STATE_DIR/promotion-paused}"

current_openclaw_version() {
  openclaw --version 2>/dev/null | head -n 1 | awk '{print $2}' | tr -d '[:space:]'
}

ensure_release_state_file() {
  ensure_release_watch_state_file "$STATE_FILE"
}

update_canary_state() {
  local status="$1"
  local version="${2:-}"
  local now tmp

  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  init_clawops_layout
  ensure_release_state_file

  if [[ -z "$version" ]]; then
    version="$(current_openclaw_version)"
  fi
  if [[ -z "$version" ]]; then
    version="unknown"
  fi

  now="$(utc_now)"
  state_update_json_locked \
    "$STATE_FILE" \
    "release-watch-state" \
    '. + {lastCanaryVersion:$v,lastCanaryStatus:$s,lastCanaryAt:$now}' \
    --arg v "$version" \
    --arg s "$status" \
    --arg now "$now"
}

update_promotion_state() {
  local status="$1"
  local paused="$2"
  local reason="${3:-}"
  local now

  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  init_clawops_layout
  ensure_release_state_file
  now="$(utc_now)"
  state_update_json_locked \
    "$STATE_FILE" \
    "release-watch-state" \
    '. + {lastPromotionStatus:$s,lastPromotionAt:$now,promotionPaused:$paused,promotionPausedAt:(if $paused then $now else null end),promotionPauseReason:(if $paused then $reason else null end)}' \
    --arg s "$status" \
    --arg now "$now" \
    --arg reason "$reason" \
    --argjson paused "$paused"
}

pause_promotion() {
  local reason="$1"
  printf '%s %s\n' "$(utc_now)" "$reason" >"$PROMOTION_PAUSE_FILE"
  update_promotion_state "paused" true "$reason"
}

run_cmd() {
  local name="$1"
  local cmd="$2"
  log_line "RUN $name: $cmd"
  if bash -lc "$cmd"; then
    append_event "$name" "ok" "$cmd"
    return 0
  fi
  append_event "$name" "error" "$cmd"
  return 1
}

self_heal_then_optional_reboot() {
  local heal_failed=0

  if [[ -n "$SELF_HEAL_CMD" ]]; then
    if ! run_cmd "self-heal" "$SELF_HEAL_CMD"; then
      heal_failed=1
    fi
  else
    log_line "WARN self-heal command not configured"
    heal_failed=1
  fi

  if "$SCRIPT_DIR/smoke-suite.sh"; then
    log_line "self-heal recovered service health"
    return 0
  fi

  if [[ "$ENABLE_REBOOT" == "1" && -n "$REBOOT_CMD" ]]; then
    run_cmd "conditional-reboot" "$REBOOT_CMD" || true
    notify_operator "conditional reboot executed after failed self-heal"
    append_event "reboot-escalation" "warn" "self-heal failed before reboot"
  else
    log_line "WARN reboot skipped (ENABLE_REBOOT=$ENABLE_REBOOT, REBOOT_CMD configured=$([[ -n "$REBOOT_CMD" ]] && echo yes || echo no))"
  fi

  return "$heal_failed"
}

if ! command -v openclaw >/dev/null 2>&1; then
  log_line "ERROR openclaw CLI required"
  exit 1
fi

main() {
  local current_version

  if is_memory_pressure; then
    mark_heavy_pause "canary-promote-memory-pressure"
    notify_operator "canary pipeline paused due to memory pressure"
    append_event "canary-pipeline" "error" "memory-pressure"
    update_canary_state "error"
    return 1
  fi

  clear_heavy_pause

  current_version="$(current_openclaw_version)"
  if [[ -z "$current_version" ]]; then
    current_version="unknown"
  fi

  if [[ "$CANARY_PREFLIGHT_ENABLED" == "1" ]]; then
    if [[ -z "$CANARY_PREFLIGHT_CMD" ]]; then
      log_line "ERROR preflight enabled but CLAWOPS_CANARY_PREFLIGHT_CMD is empty"
      update_canary_state "error" "$current_version"
      return 1
    fi
    if ! run_cmd "canary-preflight" "$CANARY_PREFLIGHT_CMD"; then
      notify_operator "canary preflight failed; update aborted"
      append_event "canary-pipeline" "error" "preflight-failed"
      update_canary_state "error" "$current_version"
      return 1
    fi
  fi

  snapshot_id="$(create_runtime_snapshot "pre-canary-update")"
  append_event "canary-pipeline" "ok" "snapshot=$snapshot_id"
  "$SCRIPT_DIR/secrets-recover.sh" --backup-only || true

  prev_version="$current_version"

  if ! run_cmd "canary-update-dry-run" "$CANARY_DRY_RUN_CMD"; then
    notify_operator "canary dry-run failed"
    update_canary_state "error" "$prev_version"
    return 1
  fi

  if ! run_cmd "canary-update-apply" "$CANARY_APPLY_CMD"; then
    notify_operator "canary update apply failed"
    update_canary_state "error" "$prev_version"
    "$SCRIPT_DIR/rollback-baseline.sh" --snapshot-id "$snapshot_id" --skip-validate || true
    return 1
  fi

  if ! "$SCRIPT_DIR/smoke-suite.sh"; then
    notify_operator "canary smoke failed; starting rollback"
    update_canary_state "error"

    if [[ -n "$CANARY_ROLLBACK_CMD" ]]; then
      run_cmd "canary-package-rollback" "$CANARY_ROLLBACK_CMD" || true
    elif [[ "$prev_version" != "unknown" ]]; then
      run_cmd "canary-package-rollback" "npm i -g openclaw@${prev_version}" || true
    fi

    "$SCRIPT_DIR/rollback-baseline.sh" --snapshot-id "$snapshot_id" --skip-validate || true
    self_heal_then_optional_reboot || true
    append_event "canary-pipeline" "error" "smoke-failed snapshot=$snapshot_id"
    return 1
  fi

  append_event "canary-pipeline" "ok" "canary green"
  notify_operator "canary update passed smoke checks"
  update_canary_state "ok"

  if [[ "$PROMOTE_ON_GREEN" != "1" ]]; then
    append_event "promotion" "skipped" "PROMOTE_ON_GREEN=$PROMOTE_ON_GREEN"
    update_promotion_state "skipped" false ""
    return 0
  fi

  if [[ -f "$PROMOTION_PAUSE_FILE" ]]; then
    append_event "promotion" "blocked" "promotion paused ($PROMOTION_PAUSE_FILE)"
    notify_operator "promotion blocked: pause file present ($PROMOTION_PAUSE_FILE)"
    update_promotion_state "blocked" true "pause file present"
    return 1
  fi

  if [[ -z "$PROD_PROMOTE_CMD" ]]; then
    notify_operator "promotion blocked: PROD promote command is not configured"
    append_event "promotion" "error" "missing CLAWOPS_PROD_PROMOTE_CMD"
    update_promotion_state "error" false "missing CLAWOPS_PROD_PROMOTE_CMD"
    return 1
  fi

  if [[ -z "$PROD_ROLLBACK_CMD" ]]; then
    notify_operator "promotion blocked: PROD rollback command is not configured"
    append_event "promotion" "error" "missing CLAWOPS_PROD_ROLLBACK_CMD"
    update_promotion_state "error" false "missing CLAWOPS_PROD_ROLLBACK_CMD"
    return 1
  fi

  if ! run_cmd "prod-promote" "$PROD_PROMOTE_CMD"; then
    notify_operator "production promote command failed"
    append_event "promotion" "error" "promote command failed"
    update_promotion_state "error" false "promote command failed"
    return 1
  fi

  if ! run_cmd "prod-smoke" "$PROD_SMOKE_CMD"; then
    notify_operator "production smoke failed after promote"
    run_cmd "prod-rollback" "$PROD_ROLLBACK_CMD" || true
    pause_promotion "prod-smoke-failed"
    append_event "promotion" "error" "prod smoke failed; rollback attempted; promotion paused"
    return 1
  fi

  append_event "promotion" "ok" "production promotion and smoke passed"
  notify_operator "production promotion completed successfully"
  update_promotion_state "ok" false ""
}

if with_lock "canary-pipeline" main; then
  exit 0
fi

rc=$?
if [[ "$rc" -eq 99 ]]; then
  append_event "canary-pipeline" "skipped" "lock-busy"
  exit 0
fi
exit "$rc"
