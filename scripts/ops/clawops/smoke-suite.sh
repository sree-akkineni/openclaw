#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ops/clawops/lib.sh
source "$SCRIPT_DIR/lib.sh"

ACP_AGENT_ID="${CLAWOPS_ACP_AGENT_ID:-codex}"
# Use a non-ACP session key by default so continuity checks work even when ACP
# metadata has not been pre-seeded for this runtime.
ACP_SESSION_KEY="${CLAWOPS_ACP_SESSION_KEY:-agent:${ACP_AGENT_ID}:clawops-smoke}"
BROWSER_PROFILE="${CLAWOPS_BROWSER_PROFILE:-openclaw}"
BROWSER_SMOKE_URL="${CLAWOPS_BROWSER_SMOKE_URL:-https://example.com}"
SMOKE_TIMEOUT_SEC="${CLAWOPS_SMOKE_TIMEOUT_SEC:-45}"
BROWSER_RETRIES="${CLAWOPS_BROWSER_RETRIES:-2}"
BROWSER_RETRY_DELAY_SEC="${CLAWOPS_BROWSER_RETRY_DELAY_SEC:-5}"
BROWSER_SETTLE_SEC="${CLAWOPS_BROWSER_SETTLE_SEC:-3}"

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
  log_line "CHECK $name"
  if "$@"; then
    append_event "smoke:$name" "ok"
    return 0
  fi
  log_line "ERROR smoke check failed: $name"
  append_event "smoke:$name" "error"
  return 1
}

run_check_retry() {
  local name="$1"
  local attempts="$2"
  local delay_sec="$3"
  shift 3

  local attempt=1
  while (( attempt <= attempts )); do
    log_line "CHECK $name attempt=$attempt/$attempts"
    if "$@"; then
      append_event "smoke:$name" "ok" "attempt=$attempt"
      return 0
    fi
    if (( attempt < attempts )); then
      log_line "WARN smoke check failed: $name attempt=$attempt; retrying in ${delay_sec}s"
      sleep "$delay_sec"
    fi
    attempt=$((attempt + 1))
  done

  log_line "ERROR smoke check failed: $name attempts=$attempts"
  append_event "smoke:$name" "error" "attempts=$attempts"
  return 1
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

smoke_body() {
  local failures=0
  local acp_turn1_idempotency_key
  local acp_turn2_idempotency_key
  acp_turn1_idempotency_key="clawops-smoke-turn1-$(date +%s)-$RANDOM"
  acp_turn2_idempotency_key="clawops-smoke-turn2-$(date +%s)-$RANDOM"

  if is_memory_pressure; then
    mark_heavy_pause "smoke-suite-memory-pressure"
    log_line "WARN memory pressure detected before smoke run"
  else
    clear_heavy_pause
  fi

  run_check "gateway-health" run_timeout openclaw health >/dev/null 2>&1 || failures=1
  run_check "channels-probe" run_timeout openclaw channels status --probe >/dev/null 2>&1 || failures=1

  # Session turn + continuity via two turns on the same session key.
  run_check "session-turn-1" \
    run_timeout openclaw gateway call agent \
      --expect-final \
      --timeout 120000 \
      --params "{\"agentId\":\"${ACP_AGENT_ID}\",\"sessionKey\":\"${ACP_SESSION_KEY}\",\"message\":\"ACP smoke turn one. Reply with ACP_SMOKE_OK_1\",\"idempotencyKey\":\"${acp_turn1_idempotency_key}\"}" \
      --json >/dev/null 2>&1 || failures=1

  run_check "session-turn-2" \
    run_timeout openclaw gateway call agent \
      --expect-final \
      --timeout 120000 \
      --params "{\"agentId\":\"${ACP_AGENT_ID}\",\"sessionKey\":\"${ACP_SESSION_KEY}\",\"message\":\"ACP smoke turn two. Reply with ACP_SMOKE_OK_2\",\"idempotencyKey\":\"${acp_turn2_idempotency_key}\"}" \
      --json >/dev/null 2>&1 || failures=1

  # Playwright + PDF coverage using browser profile actions.
  run_check_retry "browser-start" "$BROWSER_RETRIES" "$BROWSER_RETRY_DELAY_SEC" \
    run_timeout openclaw browser --browser-profile "$BROWSER_PROFILE" start >/dev/null 2>&1 || failures=1
  sleep "$BROWSER_SETTLE_SEC"
  run_check_retry "browser-open" "$BROWSER_RETRIES" "$BROWSER_RETRY_DELAY_SEC" \
    run_timeout openclaw browser --browser-profile "$BROWSER_PROFILE" open "$BROWSER_SMOKE_URL" >/dev/null 2>&1 || failures=1
  sleep "$BROWSER_SETTLE_SEC"
  run_check_retry "browser-snapshot" "$BROWSER_RETRIES" "$BROWSER_RETRY_DELAY_SEC" \
    run_timeout openclaw browser --browser-profile "$BROWSER_PROFILE" snapshot >/dev/null 2>&1 || failures=1
  sleep "$BROWSER_SETTLE_SEC"
  run_check_retry "browser-pdf" "$BROWSER_RETRIES" "$BROWSER_RETRY_DELAY_SEC" \
    run_timeout openclaw browser --browser-profile "$BROWSER_PROFILE" pdf >/dev/null 2>&1 || failures=1

  if check_required_secret "HIMALAYA_PASSWORD"; then
    append_event "smoke:himalaya-secret" "ok"
  else
    log_line "ERROR HIMALAYA_PASSWORD missing"
    append_event "smoke:himalaya-secret" "error"
    failures=1
  fi

  if check_required_secret "GMAIL_APP_PASSWORD"; then
    append_event "smoke:gmail-secret" "ok"
  else
    log_line "ERROR GMAIL_APP_PASSWORD missing"
    append_event "smoke:gmail-secret" "error"
    failures=1
  fi

  if [[ -n "${CLAWOPS_HIMALAYA_GMAIL_CHECK_CMD:-}" ]]; then
    run_check "himalaya-gmail-command" run_timeout bash -lc "$CLAWOPS_HIMALAYA_GMAIL_CHECK_CMD" >/dev/null 2>&1 || failures=1
  fi

  run_check "gateway-rpc" run_timeout openclaw gateway status --require-rpc >/dev/null 2>&1 || failures=1

  if (( failures > 0 )); then
    return 1
  fi
  return 0
}

if ! command -v openclaw >/dev/null 2>&1; then
  log_line "ERROR openclaw CLI is required for smoke-suite"
  exit 1
fi

if with_lock "heavy-smoke" smoke_body; then
  append_event "smoke-suite" "ok" "all checks green"
  notify_operator "smoke suite passed"
  exit 0
fi

append_event "smoke-suite" "error" "one or more checks failed"
notify_operator "smoke suite failed"
exit 1
