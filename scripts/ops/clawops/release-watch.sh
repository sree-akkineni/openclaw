#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ops/clawops/lib.sh
source "$SCRIPT_DIR/lib.sh"

STATE_FILE="$(release_watch_state_file)"
VERSION_CMD="${CLAWOPS_RELEASE_VERSION_CMD:-npm view openclaw version}"
RUN_CANARY_ON_NEW_RELEASE="${CLAWOPS_RUN_CANARY_ON_NEW_RELEASE:-1}"

require_cmd jq
init_clawops_layout

main() {
  ensure_release_watch_state_file "$STATE_FILE"

  latest_version="$(bash -lc "$VERSION_CMD" | tail -n 1 | tr -d '"[:space:]')"
  if [[ -z "$latest_version" ]]; then
    append_event "release-watch" "error" "failed to resolve latest version"
    notify_operator "release watcher failed to resolve latest openclaw version"
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

    append_event "release-watch" "ok" "new version detected $latest_version (prev=${prev_seen:-none})"
    notify_operator "new openclaw release detected: ${latest_version} (previous ${prev_seen:-none})"

    if [[ "$RUN_CANARY_ON_NEW_RELEASE" == "1" ]]; then
      if "$SCRIPT_DIR/canary-promote.sh"; then
        state_update_json_locked \
          "$STATE_FILE" \
          "release-watch-state" \
          '. + {lastCanaryVersion:$v,lastCanaryStatus:"ok",lastCanaryAt:$now}' \
          --arg v "$latest_version" \
          --arg now "$now"
        append_event "release-watch" "ok" "canary pipeline succeeded for $latest_version"
      else
        state_update_json_locked \
          "$STATE_FILE" \
          "release-watch-state" \
          '. + {lastCanaryVersion:$v,lastCanaryStatus:"error",lastCanaryAt:$now}' \
          --arg v "$latest_version" \
          --arg now "$now"
        append_event "release-watch" "error" "canary pipeline failed for $latest_version"
        notify_operator "canary pipeline failed for openclaw ${latest_version}"
        return 1
      fi
    fi

    return 0
  fi

  append_event "release-watch" "ok" "no new release (still $latest_version)"
  return 0
}

if with_lock "release-watch-pipeline" main; then
  exit 0
fi

rc=$?
if [[ "$rc" -eq 99 ]]; then
  append_event "release-watch" "skipped" "lock-busy"
  exit 0
fi
exit "$rc"
