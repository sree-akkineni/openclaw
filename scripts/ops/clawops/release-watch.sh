#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ops/clawops/lib.sh
source "$SCRIPT_DIR/lib.sh"

STATE_FILE="$(release_watch_state_file)"
VERSION_CMD="${CLAWOPS_RELEASE_VERSION_CMD:-npm view openclaw version}"
RUN_CANARY_ON_NEW_RELEASE="${CLAWOPS_RUN_CANARY_ON_NEW_RELEASE:-1}"
TRIGGER_MODE="${CLAWOPS_RELEASE_TRIGGER_MODE:-poll}"
FORCED_VERSION="${CLAWOPS_RELEASE_WEBHOOK_VERSION:-}"
WEBHOOK_FORCE_CANARY="${CLAWOPS_WEBHOOK_FORCE_CANARY:-0}"

usage() {
  cat <<'USAGE'
Usage:
  release-watch.sh [--trigger-mode poll|webhook] [--forced-version X.Y.Z] [--webhook-force-canary 0|1]
USAGE
}

run_canary_for_version() {
  local version="$1"
  local now
  now="$(utc_now)"

  if [[ "$RUN_CANARY_ON_NEW_RELEASE" != "1" ]]; then
    append_event "release-watch" "ok" "canary disabled for $version"
    return 0
  fi

  if "$SCRIPT_DIR/canary-promote.sh"; then
    state_update_json_locked \
      "$STATE_FILE" \
      "release-watch-state" \
      '. + {lastCanaryVersion:$v,lastCanaryStatus:"ok",lastCanaryAt:$now}' \
      --arg v "$version" \
      --arg now "$now"
    append_event "release-watch" "ok" "canary pipeline succeeded for $version"
    emit_webhook_event "release-watch.canary" "ok" "version=$version trigger=$TRIGGER_MODE" || true
    return 0
  fi

  state_update_json_locked \
    "$STATE_FILE" \
    "release-watch-state" \
    '. + {lastCanaryVersion:$v,lastCanaryStatus:"error",lastCanaryAt:$now}' \
    --arg v "$version" \
    --arg now "$now"
  append_event "release-watch" "error" "canary pipeline failed for $version"
  notify_operator "canary pipeline failed for openclaw ${version}"
  emit_webhook_event "release-watch.canary" "error" "version=$version trigger=$TRIGGER_MODE" || true
  return 1
}

main() {
  require_cmd jq
  init_clawops_layout
  ensure_release_watch_state_file "$STATE_FILE"

  if [[ -n "$FORCED_VERSION" ]]; then
    latest_version="$(printf '%s' "$FORCED_VERSION" | tr -d '"[:space:]')"
  else
    latest_version="$(bash -lc "$VERSION_CMD" | tail -n 1 | tr -d '"[:space:]')"
  fi
  if [[ -z "$latest_version" ]]; then
    append_event "release-watch" "error" "failed to resolve latest version"
    notify_operator "release watcher failed to resolve latest openclaw version"
    emit_webhook_event "release-watch" "error" "failed to resolve latest version trigger=$TRIGGER_MODE" || true
    return 1
  fi

  prev_seen="$(jq -r '.lastSeenVersion // empty' "$STATE_FILE")"
  now="$(utc_now)"

  if [[ "$latest_version" != "$prev_seen" ]]; then
    state_update_json_locked \
      "$STATE_FILE" \
      "release-watch-state" \
      '. + {lastSeenVersion:$v,lastSeenAt:$now,lastAlertedVersion:$v,lastAlertedAt:$now}' \
      --arg v "$latest_version" \
      --arg now "$now"

    append_event "release-watch" "ok" "new version detected $latest_version (prev=${prev_seen:-none}) trigger=$TRIGGER_MODE"
    notify_operator "new openclaw release detected: ${latest_version} (previous ${prev_seen:-none})"
    emit_webhook_event "release-watch.detected" "ok" "version=$latest_version prev=${prev_seen:-none} trigger=$TRIGGER_MODE" || true
    run_canary_for_version "$latest_version" || return 1

    return 0
  fi

  if [[ "$TRIGGER_MODE" == "webhook" && "$WEBHOOK_FORCE_CANARY" == "1" ]]; then
    append_event "release-watch" "ok" "no new release; forced canary for $latest_version trigger=$TRIGGER_MODE"
    notify_operator "release webhook forced canary for current version ${latest_version}"
    emit_webhook_event "release-watch.detected" "ok" "version=$latest_version prev=$prev_seen forced-canary=1 trigger=$TRIGGER_MODE" || true
    run_canary_for_version "$latest_version" || return 1
    return 0
  fi

  append_event "release-watch" "ok" "no new release (still $latest_version) trigger=$TRIGGER_MODE"
  emit_webhook_event "release-watch.detected" "ok" "version=$latest_version prev=$prev_seen changed=0 trigger=$TRIGGER_MODE" || true
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --trigger-mode)
      TRIGGER_MODE="${2:-}"
      shift 2
      ;;
    --forced-version)
      FORCED_VERSION="${2:-}"
      shift 2
      ;;
    --webhook-force-canary)
      WEBHOOK_FORCE_CANARY="${2:-0}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_line "ERROR unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if with_lock "release-watch-pipeline" main; then
  exit 0
fi

rc=$?
if [[ "$rc" -eq 99 ]]; then
  append_event "release-watch" "skipped" "lock-busy"
  exit 0
fi
exit "$rc"
