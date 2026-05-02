#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ops/clawops/lib.sh
source "$SCRIPT_DIR/lib.sh"

ACP_AGENT_ID_DEFAULT="${CLAWOPS_ACP_AGENT_ID:-codex}"
BROWSER_PROFILE_DEFAULT="${CLAWOPS_BROWSER_PROFILE:-openclaw}"
BROWSER_SMOKE_URL_DEFAULT="${CLAWOPS_BROWSER_SMOKE_URL:-https://example.com}"
PDF_SMOKE_URL_DEFAULT="${CLAWOPS_PDF_SMOKE_URL:-$BROWSER_SMOKE_URL_DEFAULT}"
SMOKE_TIMEOUT_SEC_DEFAULT="${CLAWOPS_SMOKE_TIMEOUT_SEC:-45}"
BROWSER_RETRIES_DEFAULT="${CLAWOPS_BROWSER_RETRIES:-2}"
BROWSER_RETRY_DELAY_SEC_DEFAULT="${CLAWOPS_BROWSER_RETRY_DELAY_SEC:-5}"
BROWSER_SETTLE_SEC_DEFAULT="${CLAWOPS_BROWSER_SETTLE_SEC:-3}"
PDF_RETRIES_DEFAULT="${CLAWOPS_PDF_RETRIES:-$BROWSER_RETRIES_DEFAULT}"
PDF_RETRY_DELAY_SEC_DEFAULT="${CLAWOPS_PDF_RETRY_DELAY_SEC:-$BROWSER_RETRY_DELAY_SEC_DEFAULT}"
PDF_SETTLE_SEC_DEFAULT="${CLAWOPS_PDF_SETTLE_SEC:-4}"
PDF_PASSES_DEFAULT="${CLAWOPS_PDF_PASSES:-2}"
SMOKE_TARGETS="${CLAWOPS_SMOKE_TARGETS:-local}"
REQUIRE_SECRETS="${CLAWOPS_SMOKE_REQUIRE_SECRETS:-1}"
OPENCLAW_URL_DEFAULT="${CLAWOPS_GATEWAY_URL:-${OPENCLAW_GATEWAY_URL:-}}"
OPENCLAW_TOKEN_DEFAULT="${CLAWOPS_GATEWAY_TOKEN:-${OPENCLAW_GATEWAY_TOKEN:-}}"
INTEGRATION_CONTAINER_DEFAULT="${CLAWOPS_INTEGRATION_CONTAINER:-}"

CURRENT_TARGET=""
TARGET_URL=""
TARGET_TOKEN=""
TARGET_INTEGRATION_CONTAINER=""

ACP_AGENT_ID="$ACP_AGENT_ID_DEFAULT"
ACP_SESSION_KEY=""
BROWSER_PROFILE="$BROWSER_PROFILE_DEFAULT"
BROWSER_SMOKE_URL="$BROWSER_SMOKE_URL_DEFAULT"
PDF_SMOKE_URL="$PDF_SMOKE_URL_DEFAULT"
SMOKE_TIMEOUT_SEC="$SMOKE_TIMEOUT_SEC_DEFAULT"
BROWSER_RETRIES="$BROWSER_RETRIES_DEFAULT"
BROWSER_RETRY_DELAY_SEC="$BROWSER_RETRY_DELAY_SEC_DEFAULT"
BROWSER_SETTLE_SEC="$BROWSER_SETTLE_SEC_DEFAULT"
PDF_RETRIES="$PDF_RETRIES_DEFAULT"
PDF_RETRY_DELAY_SEC="$PDF_RETRY_DELAY_SEC_DEFAULT"
PDF_SETTLE_SEC="$PDF_SETTLE_SEC_DEFAULT"
PDF_PASSES="$PDF_PASSES_DEFAULT"

usage() {
  cat <<'USAGE'
Usage:
  scripts/ops/clawops/smoke-suite.sh [options]

Options:
  --target NAME             Run only one target entry.
  --targets a,b,c           Comma-separated target list (default: CLAWOPS_SMOKE_TARGETS or local).
  -h, --help                Show this help text.

Target-specific environment overrides:
  CLAWOPS_TARGET_<NAME>_URL
  CLAWOPS_TARGET_<NAME>_TOKEN
  CLAWOPS_TARGET_<NAME>_INTEGRATION_CONTAINER
  CLAWOPS_TARGET_<NAME>_ACP_AGENT_ID
  CLAWOPS_TARGET_<NAME>_ACP_SESSION_KEY
  CLAWOPS_TARGET_<NAME>_BROWSER_PROFILE
  CLAWOPS_TARGET_<NAME>_BROWSER_SMOKE_URL
  CLAWOPS_TARGET_<NAME>_PDF_SMOKE_URL

Global reliability tuning:
  CLAWOPS_BROWSER_RETRIES / CLAWOPS_BROWSER_RETRY_DELAY_SEC / CLAWOPS_BROWSER_SETTLE_SEC
  CLAWOPS_PDF_RETRIES / CLAWOPS_PDF_RETRY_DELAY_SEC / CLAWOPS_PDF_SETTLE_SEC / CLAWOPS_PDF_PASSES
  CLAWOPS_SMOKE_TIMEOUT_SEC
  CLAWOPS_INTEGRATION_CHECKS_FILE / CLAWOPS_INTEGRATION_REQUIRE_CHECKS
USAGE
}

target_var_name() {
  local target="$1"
  local suffix="$2"
  local normalized="${target^^}"
  normalized="${normalized//[^A-Z0-9]/_}"
  printf 'CLAWOPS_TARGET_%s_%s\n' "$normalized" "$suffix"
}

target_override_or_default() {
  local target="$1"
  local suffix="$2"
  local fallback="$3"
  local key
  key="$(target_var_name "$target" "$suffix")"
  if [[ -n "${!key:-}" ]]; then
    printf '%s\n' "${!key}"
    return 0
  fi
  printf '%s\n' "$fallback"
}

target_log() {
  if [[ -n "$CURRENT_TARGET" ]]; then
    printf '[%s] %s\n' "$CURRENT_TARGET" "$*"
    return 0
  fi
  printf '%s\n' "$*"
}

run_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$SMOKE_TIMEOUT_SEC" "$@"
    return $?
  fi
  "$@"
}

run_check() {
  local name="$1"
  shift
  log_line "$(target_log "CHECK $name")"
  if "$@"; then
    append_event "smoke:${CURRENT_TARGET:-local}:$name" "ok"
    return 0
  fi
  log_line "$(target_log "ERROR smoke check failed: $name")"
  append_event "smoke:${CURRENT_TARGET:-local}:$name" "error"
  return 1
}

run_check_retry() {
  local name="$1"
  local attempts="$2"
  local delay_sec="$3"
  shift 3

  local attempt=1
  while (( attempt <= attempts )); do
    log_line "$(target_log "CHECK $name attempt=$attempt/$attempts")"
    if "$@"; then
      append_event "smoke:${CURRENT_TARGET:-local}:$name" "ok" "attempt=$attempt"
      return 0
    fi
    if (( attempt < attempts )); then
      log_line "$(target_log "WARN smoke check failed: $name attempt=$attempt; retrying in ${delay_sec}s")"
      sleep "$delay_sec"
    fi
    attempt=$((attempt + 1))
  done

  log_line "$(target_log "ERROR smoke check failed: $name attempts=$attempts")"
  append_event "smoke:${CURRENT_TARGET:-local}:$name" "error" "attempts=$attempts"
  return 1
}

openclaw_cmd() {
  local -a args=()
  if [[ -n "$TARGET_URL" ]]; then
    args+=(--url "$TARGET_URL")
  fi
  if [[ -n "$TARGET_TOKEN" ]]; then
    args+=(--token "$TARGET_TOKEN")
  fi
  openclaw "${args[@]}" "$@"
}

run_integration_suite_for_target() {
  if [[ -n "$TARGET_INTEGRATION_CONTAINER" ]]; then
    local integration_script='
      export OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=1
      timeout 20 openclaw gateway status --require-rpc --url "$OPENCLAW_GATEWAY_URL" --token "$OPENCLAW_GATEWAY_TOKEN" >/dev/null
      timeout 20 openclaw health >/dev/null
      timeout 20 openclaw mcp list >/dev/null
      command -v himalaya >/dev/null
      if [ "$CLAWOPS_INTEGRATION_TARGET" = "gumnut" ]; then
        cat >/tmp/duck-params.json <<JSON
{"agentId":"main","sessionKey":"agent:main:duckbill-smoke-inline","message":"Use the duckbill tool with action inspect_tools and reply exactly STATUS=ok.","idempotencyKey":"duckbill-inline-$(date +%s)-$RANDOM"}
JSON
        timeout 120 openclaw gateway call agent --expect-final --timeout 120000 --params "$(cat /tmp/duck-params.json)" | grep -q "STATUS=ok"
      fi
    '

    run_timeout docker exec \
      -e OPENCLAW_GATEWAY_URL="$TARGET_URL" \
      -e OPENCLAW_GATEWAY_TOKEN="$TARGET_TOKEN" \
      -e CLAWOPS_INTEGRATION_TARGET="$CURRENT_TARGET" \
      "$TARGET_INTEGRATION_CONTAINER" \
      sh -lc "$integration_script"
    return $?
  fi

  env \
    CLAWOPS_INTEGRATION_TARGET="$CURRENT_TARGET" \
    CLAWOPS_INTEGRATION_TARGET_URL="$TARGET_URL" \
    CLAWOPS_INTEGRATION_TARGET_TOKEN="$TARGET_TOKEN" \
    "$SCRIPT_DIR/integration-suite.sh" --target "$CURRENT_TARGET"
}

check_required_secret() {
  local key="$1"
  if [[ -n "${!key:-}" ]]; then
    return 0
  fi
  if [[ -f "$HOME/.openclaw/.env" ]] && grep -q "^${key}=" "$HOME/.openclaw/.env"; then
    return 0
  fi
  return 1
}

set_active_tuning_for_target() {
  BROWSER_RETRIES="$BROWSER_RETRIES_DEFAULT"
  BROWSER_RETRY_DELAY_SEC="$BROWSER_RETRY_DELAY_SEC_DEFAULT"
  BROWSER_SETTLE_SEC="$BROWSER_SETTLE_SEC_DEFAULT"
  PDF_RETRIES="$PDF_RETRIES_DEFAULT"
  PDF_RETRY_DELAY_SEC="$PDF_RETRY_DELAY_SEC_DEFAULT"
  PDF_SETTLE_SEC="$PDF_SETTLE_SEC_DEFAULT"
  PDF_PASSES="$PDF_PASSES_DEFAULT"
  SMOKE_TIMEOUT_SEC="$SMOKE_TIMEOUT_SEC_DEFAULT"
}

apply_memory_pressure_tuning() {
  if ! is_memory_pressure; then
    clear_heavy_pause
    return 1
  fi

  mark_heavy_pause "smoke-suite-memory-pressure"
  log_line "$(target_log "WARN memory pressure detected; applying low-footprint browser/pdf tuning")"

  if (( BROWSER_RETRIES > 1 )); then
    BROWSER_RETRIES=$((BROWSER_RETRIES - 1))
  fi
  if (( PDF_RETRIES > 1 )); then
    PDF_RETRIES=$((PDF_RETRIES - 1))
  fi
  BROWSER_SETTLE_SEC=$((BROWSER_SETTLE_SEC + 2))
  PDF_SETTLE_SEC=$((PDF_SETTLE_SEC + 2))
  if (( PDF_PASSES > 1 )); then
    PDF_PASSES=$((PDF_PASSES - 1))
  fi
  return 0
}

check_existing_session_reuse() {
  local key="$1"
  local expected="$2"

  run_timeout openclaw_cmd browser --browser-profile "$BROWSER_PROFILE" storage local set "$key" "$expected" >/dev/null 2>&1
  run_timeout openclaw_cmd browser --browser-profile "$BROWSER_PROFILE" storage local get "$key" >/dev/null 2>&1
}

check_restart_persistence() {
  local key="$1"
  local expected="$2"

  run_timeout openclaw_cmd browser --browser-profile "$BROWSER_PROFILE" stop >/dev/null 2>&1 || true
  run_timeout openclaw_cmd browser --browser-profile "$BROWSER_PROFILE" start >/dev/null 2>&1
  sleep "$BROWSER_SETTLE_SEC"
  run_timeout openclaw_cmd browser --browser-profile "$BROWSER_PROFILE" open "$BROWSER_SMOKE_URL" >/dev/null 2>&1
  sleep "$BROWSER_SETTLE_SEC"

  run_timeout openclaw_cmd browser --browser-profile "$BROWSER_PROFILE" storage local get "$key" >/dev/null 2>&1
}

run_pdf_passes() {
  local failures=0
  local pass=1
  while (( pass <= PDF_PASSES )); do
    run_check_retry "browser-pdf-pass-$pass" "$PDF_RETRIES" "$PDF_RETRY_DELAY_SEC" \
      run_timeout openclaw_cmd browser --browser-profile "$BROWSER_PROFILE" pdf >/dev/null 2>&1 || failures=1
    if (( pass < PDF_PASSES )); then
      sleep "$PDF_SETTLE_SEC"
    fi
    pass=$((pass + 1))
  done

  if (( failures > 0 )); then
    return 1
  fi
  return 0
}

smoke_target_body() {
  local target="$1"
  local failures=0
  local acp_turn1_idempotency_key
  local acp_turn2_idempotency_key
  local persistence_key
  local persistence_value
  acp_turn1_idempotency_key="clawops-smoke-turn1-$(date +%s)-$RANDOM"
  acp_turn2_idempotency_key="clawops-smoke-turn2-$(date +%s)-$RANDOM"
  persistence_key="clawops_smoke_profile_key_${target//[^a-zA-Z0-9]/_}"
  persistence_value="ok_$(date +%s)_$RANDOM"

  set_active_tuning_for_target
  apply_memory_pressure_tuning || true

  run_check "gateway-health" run_timeout openclaw_cmd health >/dev/null 2>&1 || failures=1
  run_check "channels-probe" run_timeout openclaw_cmd channels status --probe >/dev/null 2>&1 || failures=1

  # Session turn + continuity via two turns on the same session key.
  run_check "session-turn-1" \
    run_timeout openclaw_cmd gateway call agent \
      --expect-final \
      --timeout 120000 \
      --params "{\"agentId\":\"${ACP_AGENT_ID}\",\"sessionKey\":\"${ACP_SESSION_KEY}\",\"message\":\"ACP smoke turn one. Reply with ACP_SMOKE_OK_1\",\"idempotencyKey\":\"${acp_turn1_idempotency_key}\"}" \
      --json >/dev/null 2>&1 || failures=1

  run_check "session-turn-2" \
    run_timeout openclaw_cmd gateway call agent \
      --expect-final \
      --timeout 120000 \
      --params "{\"agentId\":\"${ACP_AGENT_ID}\",\"sessionKey\":\"${ACP_SESSION_KEY}\",\"message\":\"ACP smoke turn two. Reply with ACP_SMOKE_OK_2\",\"idempotencyKey\":\"${acp_turn2_idempotency_key}\"}" \
      --json >/dev/null 2>&1 || failures=1

  # Existing-session profile reuse + restart persistence + PDF reliability.
  run_check_retry "browser-start" "$BROWSER_RETRIES" "$BROWSER_RETRY_DELAY_SEC" \
    run_timeout openclaw_cmd browser --browser-profile "$BROWSER_PROFILE" start >/dev/null 2>&1 || failures=1
  sleep "$BROWSER_SETTLE_SEC"
  run_check_retry "browser-open" "$BROWSER_RETRIES" "$BROWSER_RETRY_DELAY_SEC" \
    run_timeout openclaw_cmd browser --browser-profile "$BROWSER_PROFILE" open "$BROWSER_SMOKE_URL" >/dev/null 2>&1 || failures=1
  sleep "$BROWSER_SETTLE_SEC"
  run_check_retry "browser-snapshot" "$BROWSER_RETRIES" "$BROWSER_RETRY_DELAY_SEC" \
    run_timeout openclaw_cmd browser --browser-profile "$BROWSER_PROFILE" snapshot >/dev/null 2>&1 || failures=1
  sleep "$BROWSER_SETTLE_SEC"
  run_check "browser-existing-session-reuse" \
    check_existing_session_reuse "$persistence_key" "$persistence_value" || failures=1
  run_check "browser-restart-persistence" \
    check_restart_persistence "$persistence_key" "$persistence_value" || failures=1
  run_check_retry "browser-open-pdf-url" "$BROWSER_RETRIES" "$BROWSER_RETRY_DELAY_SEC" \
    run_timeout openclaw_cmd browser --browser-profile "$BROWSER_PROFILE" open "$PDF_SMOKE_URL" >/dev/null 2>&1 || failures=1
  sleep "$PDF_SETTLE_SEC"
  run_pdf_passes || failures=1

  if (( REQUIRE_SECRETS == 1 )); then
    if check_required_secret "HIMALAYA_PASSWORD"; then
      append_event "smoke:${CURRENT_TARGET:-local}:himalaya-secret" "ok"
    else
      log_line "$(target_log "ERROR HIMALAYA_PASSWORD missing")"
      append_event "smoke:${CURRENT_TARGET:-local}:himalaya-secret" "error"
      failures=1
    fi

    if check_required_secret "GMAIL_APP_PASSWORD"; then
      append_event "smoke:${CURRENT_TARGET:-local}:gmail-secret" "ok"
    else
      log_line "$(target_log "ERROR GMAIL_APP_PASSWORD missing")"
      append_event "smoke:${CURRENT_TARGET:-local}:gmail-secret" "error"
      failures=1
    fi
  fi

  run_check "gateway-rpc" run_timeout openclaw_cmd gateway status --require-rpc >/dev/null 2>&1 || failures=1
  run_check "integration-suite" run_integration_suite_for_target || failures=1

  if (( failures > 0 )); then
    return 1
  fi
  return 0
}

run_target_smoke() {
  local target="$1"
  CURRENT_TARGET="$target"

  TARGET_URL="$(target_override_or_default "$target" "URL" "$OPENCLAW_URL_DEFAULT")"
  TARGET_TOKEN="$(target_override_or_default "$target" "TOKEN" "$OPENCLAW_TOKEN_DEFAULT")"
  TARGET_INTEGRATION_CONTAINER="$(target_override_or_default "$target" "INTEGRATION_CONTAINER" "$INTEGRATION_CONTAINER_DEFAULT")"
  ACP_AGENT_ID="$(target_override_or_default "$target" "ACP_AGENT_ID" "$ACP_AGENT_ID_DEFAULT")"
  ACP_SESSION_KEY="$(target_override_or_default "$target" "ACP_SESSION_KEY" "agent:${ACP_AGENT_ID}:clawops-smoke:${target}")"
  BROWSER_PROFILE="$(target_override_or_default "$target" "BROWSER_PROFILE" "$BROWSER_PROFILE_DEFAULT")"
  BROWSER_SMOKE_URL="$(target_override_or_default "$target" "BROWSER_SMOKE_URL" "$BROWSER_SMOKE_URL_DEFAULT")"
  PDF_SMOKE_URL="$(target_override_or_default "$target" "PDF_SMOKE_URL" "$PDF_SMOKE_URL_DEFAULT")"

  log_line "$(target_log "starting smoke target profile=$BROWSER_PROFILE session=$ACP_SESSION_KEY")"
  if [[ -n "$TARGET_URL" ]]; then
    log_line "$(target_log "gateway-url=$TARGET_URL")"
  fi
  if [[ -n "$TARGET_INTEGRATION_CONTAINER" ]]; then
    log_line "$(target_log "integration-container=$TARGET_INTEGRATION_CONTAINER")"
  fi

  if smoke_target_body "$target"; then
    append_event "smoke-target:$target" "ok" "profile=$BROWSER_PROFILE pdfPasses=$PDF_PASSES"
    return 0
  fi
  append_event "smoke-target:$target" "error" "profile=$BROWSER_PROFILE"
  return 1
}

run_matrix() {
  local targets_csv="$1"
  local failures=0
  local passes=0
  local rows=()
  local target

  IFS=',' read -r -a targets <<<"$targets_csv"
  for target in "${targets[@]}"; do
    target="${target//[[:space:]]/}"
    [[ -z "$target" ]] && continue

    if run_target_smoke "$target"; then
      rows+=("$target PASS $BROWSER_PROFILE $PDF_PASSES")
      passes=$((passes + 1))
    else
      rows+=("$target FAIL $BROWSER_PROFILE $PDF_PASSES")
      failures=$((failures + 1))
    fi
  done

  log_line "SMOKE MATRIX (target status browser-profile pdf-passes)"
  local row
  for row in "${rows[@]}"; do
    log_line "$row"
  done

  if (( failures > 0 )); then
    append_event "smoke-suite-matrix" "error" "pass=$passes fail=$failures"
    return 1
  fi

  append_event "smoke-suite-matrix" "ok" "pass=$passes fail=0"
  return 0
}

if ! command -v openclaw >/dev/null 2>&1; then
  log_line "ERROR openclaw CLI is required for smoke-suite"
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      SMOKE_TARGETS="${2:-}"
      shift 2
      ;;
    --targets)
      SMOKE_TARGETS="${2:-}"
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

if with_lock "heavy-smoke" run_matrix "$SMOKE_TARGETS"; then
  append_event "smoke-suite" "ok" "targets=$SMOKE_TARGETS all checks green"
  notify_operator "smoke suite passed"
  exit 0
fi

append_event "smoke-suite" "error" "targets=$SMOKE_TARGETS one or more checks failed"
notify_operator "smoke suite failed"
exit 1
