#!/usr/bin/env bash
set -euo pipefail

CLAWOPS_HOME="${CLAWOPS_HOME:-$HOME/.openclaw/clawops}"
CLAWOPS_STATE_DIR="${CLAWOPS_STATE_DIR:-$CLAWOPS_HOME/state}"
CLAWOPS_LOG_DIR="${CLAWOPS_LOG_DIR:-$CLAWOPS_HOME/logs}"
CLAWOPS_SNAPSHOT_DIR="${CLAWOPS_SNAPSHOT_DIR:-$CLAWOPS_HOME/snapshots}"
CLAWOPS_LOCK_DIR="${CLAWOPS_LOCK_DIR:-$CLAWOPS_HOME/locks}"
CLAWOPS_LOCKFILE="${CLAWOPS_LOCKFILE:-$CLAWOPS_STATE_DIR/baseline.lock.json}"

CLAWOPS_NOTIFY_CHANNEL="${CLAWOPS_NOTIFY_CHANNEL:-telegram}"
CLAWOPS_NOTIFY_TARGET="${CLAWOPS_NOTIFY_TARGET:-}"
CLAWOPS_NOTIFY_ACCOUNT="${CLAWOPS_NOTIFY_ACCOUNT:-}"
CLAWOPS_NOTIFY_PREFIX="${CLAWOPS_NOTIFY_PREFIX:-[clawops]}"
CLAWOPS_NOTIFY_MODE="${CLAWOPS_NOTIFY_MODE:-message}"
CLAWOPS_NOTIFY_AGENT_ID="${CLAWOPS_NOTIFY_AGENT_ID:-codex}"
CLAWOPS_NOTIFY_SESSION_KEY="${CLAWOPS_NOTIFY_SESSION_KEY:-}"
CLAWOPS_NOTIFY_AGENT_TIMEOUT_MS="${CLAWOPS_NOTIFY_AGENT_TIMEOUT_MS:-120000}"

CLAWOPS_WEBHOOK_URL="${CLAWOPS_WEBHOOK_URL:-}"
CLAWOPS_WEBHOOK_TOKEN="${CLAWOPS_WEBHOOK_TOKEN:-}"
CLAWOPS_WEBHOOK_TIMEOUT_SEC="${CLAWOPS_WEBHOOK_TIMEOUT_SEC:-10}"

CLAWOPS_MIN_AVAILABLE_MB="${CLAWOPS_MIN_AVAILABLE_MB:-350}"
CLAWOPS_MAX_SWAP_USED_MB="${CLAWOPS_MAX_SWAP_USED_MB:-1536}"

init_clawops_layout() {
  mkdir -p "$CLAWOPS_HOME" "$CLAWOPS_STATE_DIR" "$CLAWOPS_LOG_DIR" "$CLAWOPS_SNAPSHOT_DIR" "$CLAWOPS_LOCK_DIR"
}

utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_line() {
  printf '%s %s\n' "$(utc_now)" "$*"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_line "ERROR missing command: $cmd"
    return 1
  fi
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

append_event() {
  local action="$1"
  local status="$2"
  local details="${3:-}"
  init_clawops_layout
  local log_file="$CLAWOPS_LOG_DIR/operator-digest.jsonl"

  if command -v jq >/dev/null 2>&1; then
    jq -cn \
      --arg ts "$(utc_now)" \
      --arg action "$action" \
      --arg status "$status" \
      --arg details "$details" \
      '{ts:$ts,action:$action,status:$status,details:$details}' >>"$log_file"
  else
    printf '%s\t%s\t%s\t%s\n' "$(utc_now)" "$action" "$status" "$details" >>"$log_file"
  fi
}

notify_operator() {
  local text="$1"
  local body="$CLAWOPS_NOTIFY_PREFIX $text"
  log_line "$body"

  if command -v openclaw >/dev/null 2>&1; then
    local sent=0
    if [[ "$CLAWOPS_NOTIFY_MODE" == "session" || -n "$CLAWOPS_NOTIFY_SESSION_KEY" ]]; then
      if [[ -n "$CLAWOPS_NOTIFY_SESSION_KEY" ]] && command -v jq >/dev/null 2>&1; then
        local params
        local idempotency_key
        idempotency_key="clawops-notify-$(date +%s)-$RANDOM"
        params="$(jq -cn \
          --arg agentId "$CLAWOPS_NOTIFY_AGENT_ID" \
          --arg sessionKey "$CLAWOPS_NOTIFY_SESSION_KEY" \
          --arg message "$body" \
          --arg idempotencyKey "$idempotency_key" \
          '{agentId:$agentId,sessionKey:$sessionKey,message:$message,idempotencyKey:$idempotencyKey}')"
        if openclaw gateway call agent \
          --expect-final \
          --timeout "$CLAWOPS_NOTIFY_AGENT_TIMEOUT_MS" \
          --params "$params" \
          --json >/dev/null 2>&1; then
          sent=1
        else
          log_line "WARN session-targeted notify failed; falling back to direct message send"
        fi
      else
        log_line "WARN notify session mode requested but CLAWOPS_NOTIFY_SESSION_KEY or jq is missing"
      fi
    fi

    if (( sent == 0 )) && [[ -n "$CLAWOPS_NOTIFY_TARGET" ]]; then
      if [[ -n "$CLAWOPS_NOTIFY_ACCOUNT" ]]; then
        openclaw message send \
          --channel "$CLAWOPS_NOTIFY_CHANNEL" \
          --account "$CLAWOPS_NOTIFY_ACCOUNT" \
          --target "$CLAWOPS_NOTIFY_TARGET" \
          --message "$body" >/dev/null 2>&1 || true
      else
        openclaw message send \
          --channel "$CLAWOPS_NOTIFY_CHANNEL" \
          --target "$CLAWOPS_NOTIFY_TARGET" \
          --message "$body" >/dev/null 2>&1 || true
      fi
    fi
  fi
}

emit_webhook_event() {
  local event="$1"
  local status="$2"
  local details="${3:-}"

  if [[ -z "$CLAWOPS_WEBHOOK_URL" ]]; then
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log_line "WARN webhook event skipped (curl not found)"
    return 1
  fi

  local payload
  if command -v jq >/dev/null 2>&1; then
    payload="$(jq -cn \
      --arg ts "$(utc_now)" \
      --arg event "$event" \
      --arg status "$status" \
      --arg details "$details" \
      '{ts:$ts,event:$event,status:$status,details:$details}')"
  else
    payload="{\"ts\":\"$(utc_now)\",\"event\":\"$event\",\"status\":\"$status\",\"details\":\"$details\"}"
  fi

  local -a headers=("-H" "Content-Type: application/json")
  if [[ -n "$CLAWOPS_WEBHOOK_TOKEN" ]]; then
    headers+=("-H" "Authorization: Bearer $CLAWOPS_WEBHOOK_TOKEN")
  fi

  if ! curl -fsS --max-time "$CLAWOPS_WEBHOOK_TIMEOUT_SEC" "${headers[@]}" -d "$payload" "$CLAWOPS_WEBHOOK_URL" >/dev/null; then
    log_line "WARN webhook event failed: event=$event status=$status"
    return 1
  fi
  return 0
}

create_runtime_snapshot() {
  local reason="${1:-manual}"
  init_clawops_layout

  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  local snapshot_id="${ts}-${reason//[^a-zA-Z0-9._-]/-}"
  local tar_path="$CLAWOPS_SNAPSHOT_DIR/$snapshot_id.tgz"
  local meta_path="$CLAWOPS_SNAPSHOT_DIR/$snapshot_id.meta"

  local -a include_paths=(
    "$HOME/.openclaw/openclaw.json"
    "$HOME/.openclaw/exec-approvals.json"
    "$HOME/.openclaw/cron/jobs.json"
    "$HOME/.openclaw/secrets.json"
    "$HOME/.openclaw/.env"
    "$HOME/.openclaw/credentials"
    "$HOME/.openclaw/agents/main/agent/auth-profiles.json"
    "$HOME/.openclaw/workspace/AGENTS.md"
    "$HOME/.openclaw/workspace/HEARTBEAT.md"
  )

  if [[ -n "${CLAWOPS_SNAPSHOT_EXTRA:-}" ]]; then
    local extra
    IFS=',' read -r -a extra <<<"$CLAWOPS_SNAPSHOT_EXTRA"
    local item
    for item in "${extra[@]}"; do
      item="${item//[[:space:]]/}"
      [[ -n "$item" ]] && include_paths+=("$item")
    done
  fi

  local -a existing=()
  local p
  for p in "${include_paths[@]}"; do
    if [[ -e "$p" ]]; then
      existing+=("$p")
    fi
  done

  if [[ ${#existing[@]} -eq 0 ]]; then
    log_line "WARN no runtime paths available for snapshot"
    return 1
  fi

  tar -czf "$tar_path" -P "${existing[@]}"
  {
    printf 'id=%s\n' "$snapshot_id"
    printf 'ts=%s\n' "$(utc_now)"
    printf 'reason=%s\n' "$reason"
    printf 'paths=%s\n' "${existing[*]}"
  } >"$meta_path"

  append_event "snapshot" "ok" "id=$snapshot_id reason=$reason"
  printf '%s\n' "$snapshot_id"
}

latest_snapshot_id() {
  local latest
  latest="$(ls -1 "$CLAWOPS_SNAPSHOT_DIR"/*.tgz 2>/dev/null | sort | tail -n 1 || true)"
  if [[ -z "$latest" ]]; then
    return 1
  fi
  basename "$latest" .tgz
}

restore_snapshot() {
  local snapshot_id="$1"
  local tar_path="$CLAWOPS_SNAPSHOT_DIR/$snapshot_id.tgz"
  if [[ ! -f "$tar_path" ]]; then
    log_line "ERROR snapshot not found: $snapshot_id"
    return 1
  fi

  tar -xzf "$tar_path" -P
  append_event "snapshot-restore" "ok" "id=$snapshot_id"
}

with_lock() {
  local name="$1"
  shift

  local lock="$CLAWOPS_LOCK_DIR/${name}.lock"
  mkdir -p "$CLAWOPS_LOCK_DIR"

  local fd
  exec {fd}>"$lock"
  if ! flock -n "$fd"; then
    log_line "WARN lock busy: $name"
    eval "exec ${fd}>&-"
    return 99
  fi

  local rc=0
  if "$@"; then
    rc=0
  else
    rc=$?
  fi
  eval "exec ${fd}>&-"
  return "$rc"
}

release_watch_state_file() {
  printf '%s\n' "${CLAWOPS_RELEASE_STATE_FILE:-$CLAWOPS_STATE_DIR/release-watch.json}"
}

release_watch_state_defaults_json() {
  cat <<'JSON'
{"version":1,"lastSeenVersion":null,"lastSeenAt":null,"lastAlertedVersion":null,"lastAlertedAt":null,"lastCanaryVersion":null,"lastCanaryStatus":null,"lastCanaryAt":null,"lastPromotionStatus":null,"lastPromotionAt":null,"promotionPaused":false,"promotionPausedAt":null,"promotionPauseReason":null,"lastDigestDate":null}
JSON
}

ensure_release_watch_state_file() {
  local file="${1:-$(release_watch_state_file)}"
  require_cmd jq
  init_clawops_layout

  local lock="$CLAWOPS_LOCK_DIR/release-watch-state.lock"
  local fd
  exec {fd}>"$lock"
  flock "$fd"

  if [[ ! -f "$file" ]]; then
    release_watch_state_defaults_json >"$file"
  fi

  local tmp
  tmp="$(mktemp)"
  jq --argjson defaults "$(release_watch_state_defaults_json)" '
    if type != "object" then $defaults
    else reduce ($defaults | keys[]) as $k
      (.;
        if has($k) then .
        else . + { ($k): $defaults[$k] }
        end
      )
    end
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
  eval "exec ${fd}>&-"
}

state_update_json_locked() {
  local file="$1"
  local lock_name="$2"
  local jq_filter="$3"
  shift 3

  require_cmd jq
  init_clawops_layout

  local lock="$CLAWOPS_LOCK_DIR/${lock_name}.lock"
  local fd
  exec {fd}>"$lock"
  flock "$fd"

  if [[ ! -f "$file" ]]; then
    echo '{}' >"$file"
  fi

  local tmp
  tmp="$(mktemp)"
  jq "$@" "$jq_filter" "$file" >"$tmp"
  mv "$tmp" "$file"
  eval "exec ${fd}>&-"
}

memory_status_mb() {
  if [[ -r /proc/meminfo ]]; then
    local avail_kb swap_total_kb swap_free_kb
    avail_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
    swap_total_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)"
    swap_free_kb="$(awk '/SwapFree:/ {print $2}' /proc/meminfo)"
    local avail_mb swap_used_mb
    avail_mb=$((avail_kb / 1024))
    swap_used_mb=$(((swap_total_kb - swap_free_kb) / 1024))
    printf '%s %s\n' "$avail_mb" "$swap_used_mb"
    return 0
  fi

  if command -v vm_stat >/dev/null 2>&1; then
    local page_size free_pages speculative_pages
    page_size="$(vm_stat | awk -F': ' '/page size of/ {gsub(/\./, "", $2); print $2+0}')"
    free_pages="$(vm_stat | awk -F': ' '/Pages free/ {gsub(/\./, "", $2); print $2+0}')"
    speculative_pages="$(vm_stat | awk -F': ' '/Pages speculative/ {gsub(/\./, "", $2); print $2+0}')"
    local avail_bytes avail_mb
    avail_bytes=$(((free_pages + speculative_pages) * page_size))
    avail_mb=$((avail_bytes / 1024 / 1024))
    printf '%s %s\n' "$avail_mb" "0"
    return 0
  fi

  printf '0 0\n'
}

is_memory_pressure() {
  local stats avail_mb swap_used_mb
  stats="$(memory_status_mb)"
  avail_mb="${stats%% *}"
  swap_used_mb="${stats##* }"

  if (( avail_mb < CLAWOPS_MIN_AVAILABLE_MB )); then
    return 0
  fi
  if (( swap_used_mb > CLAWOPS_MAX_SWAP_USED_MB )); then
    return 0
  fi
  return 1
}

mark_heavy_pause() {
  init_clawops_layout
  local reason="${1:-memory-pressure}"
  printf '%s\n' "$(utc_now) $reason" >"$CLAWOPS_STATE_DIR/pause-heavy"
}

clear_heavy_pause() {
  rm -f "$CLAWOPS_STATE_DIR/pause-heavy"
}

baseline_lock_write() {
  local out_file="$1"
  shift
  local -a files=("$@")

  require_cmd jq

  local json='[]'
  local path
  for path in "${files[@]}"; do
    if [[ -f "$path" ]]; then
      local sum
      sum="$(sha256_file "$path")"
      json="$(jq -cn --argjson arr "$json" --arg p "$path" --arg s "$sum" '$arr + [{path:$p,sha256:$s}]')"
    fi
  done

  jq -cn \
    --arg ts "$(utc_now)" \
    --argjson files "$json" \
    '{version:1,generatedAt:$ts,files:$files}' >"$out_file"
}

baseline_lock_verify() {
  local lock_file="$1"
  if [[ ! -f "$lock_file" ]]; then
    log_line "ERROR baseline lock file missing: $lock_file"
    return 1
  fi
  require_cmd jq

  local failures=0
  while IFS='|' read -r p expected; do
    if [[ ! -f "$p" ]]; then
      log_line "ERROR drift missing file: $p"
      failures=1
      continue
    fi
    local actual
    actual="$(sha256_file "$p")"
    if [[ "$actual" != "$expected" ]]; then
      log_line "ERROR drift checksum mismatch: $p"
      failures=1
    fi
  done < <(jq -r '.files[] | "\(.path)|\(.sha256)"' "$lock_file")

  return "$failures"
}
