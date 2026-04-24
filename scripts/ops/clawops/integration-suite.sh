#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ops/clawops/lib.sh
source "$SCRIPT_DIR/lib.sh"

CHECKS_FILE="${CLAWOPS_INTEGRATION_CHECKS_FILE:-}"
REQUIRE_CHECKS="${CLAWOPS_INTEGRATION_REQUIRE_CHECKS:-0}"
TIMEOUT_SEC="${CLAWOPS_INTEGRATION_TIMEOUT_SEC:-60}"
RETRIES="${CLAWOPS_INTEGRATION_RETRIES:-1}"
RETRY_DELAY_SEC="${CLAWOPS_INTEGRATION_RETRY_DELAY_SEC:-5}"
TARGET_NAME="${CLAWOPS_INTEGRATION_TARGET:-local}"
TARGET_URL="${CLAWOPS_INTEGRATION_TARGET_URL:-${OPENCLAW_GATEWAY_URL:-}}"
TARGET_TOKEN="${CLAWOPS_INTEGRATION_TARGET_TOKEN:-${OPENCLAW_GATEWAY_TOKEN:-}}"
LEGACY_GMAIL_CMD="${CLAWOPS_HIMALAYA_GMAIL_CHECK_CMD:-}"

declare -a CHECK_SCOPE=()
declare -a CHECK_NAME=()
declare -a CHECK_CMD=()

usage() {
  cat <<'USAGE'
Usage:
  scripts/ops/clawops/integration-suite.sh [options]

Options:
  --target NAME              Tag events/logs for a target label.
  --checks-file PATH         Override CLAWOPS_INTEGRATION_CHECKS_FILE.
  --require-checks 0|1       Override CLAWOPS_INTEGRATION_REQUIRE_CHECKS.
  -h, --help                 Show this help text.

Checks file format:
  scope|name|command
  # comments are allowed

Example:
  mcp|list-providers|openclaw mcp list --json >/dev/null
  api|gateway-health|openclaw gateway status --require-rpc
  function|notion-tool|openclaw gateway call tool --params '{"name":"notion_search"}'
USAGE
}

event_safe() {
  local raw="$1"
  raw="${raw//[^a-zA-Z0-9._-]/-}"
  printf '%s\n' "$raw"
}

integration_log() {
  printf '[integration:%s] %s\n' "$TARGET_NAME" "$*"
}

append_check() {
  local scope="$1"
  local name="$2"
  local cmd="$3"
  CHECK_SCOPE+=("$scope")
  CHECK_NAME+=("$name")
  CHECK_CMD+=("$cmd")
}

run_timeout_cmd() {
  local cmd="$1"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SEC" bash -lc "$cmd"
    return $?
  fi
  bash -lc "$cmd"
}

run_check_retry() {
  local scope="$1"
  local name="$2"
  local cmd="$3"
  local attempts=1
  local scope_key name_key
  scope_key="$(event_safe "$scope")"
  name_key="$(event_safe "$name")"

  while (( attempts <= RETRIES )); do
    log_line "$(integration_log "CHECK ${scope}/${name} attempt=${attempts}/${RETRIES}")"
    if run_timeout_cmd "$cmd"; then
      append_event "integration:${TARGET_NAME}:${scope_key}:${name_key}" "ok" "attempt=$attempts"
      return 0
    fi

    if (( attempts < RETRIES )); then
      log_line "$(integration_log "WARN ${scope}/${name} failed; retrying in ${RETRY_DELAY_SEC}s")"
      sleep "$RETRY_DELAY_SEC"
    fi
    attempts=$((attempts + 1))
  done

  append_event "integration:${TARGET_NAME}:${scope_key}:${name_key}" "error" "attempts=$RETRIES"
  log_line "$(integration_log "ERROR ${scope}/${name} failed after ${RETRIES} attempt(s)")"
  return 1
}

load_checks_file() {
  local file="$1"
  local line_no=0
  local parse_failures=0
  local raw line trimmed scope name cmd

  [[ -z "$file" ]] && return 0
  if [[ ! -f "$file" ]]; then
    log_line "$(integration_log "ERROR checks file not found: $file")"
    return 1
  fi

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line_no=$((line_no + 1))
    line="${raw%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ "${trimmed#\#}" != "$trimmed" ]] && continue

    IFS='|' read -r scope name cmd <<<"$line"
    scope="${scope//[[:space:]]/}"
    name="${name//[[:space:]]/}"

    if [[ -z "$scope" || -z "$name" || -z "${cmd:-}" ]]; then
      log_line "$(integration_log "ERROR malformed check line ${line_no}: $line")"
      parse_failures=$((parse_failures + 1))
      continue
    fi

    append_check "$scope" "$name" "$cmd"
  done <"$file"

  if (( parse_failures > 0 )); then
    return 1
  fi
  return 0
}

load_legacy_checks() {
  if [[ -n "$LEGACY_GMAIL_CMD" ]]; then
    append_check "api" "himalaya-gmail-command" "$LEGACY_GMAIL_CMD"
  fi
}

main() {
  init_clawops_layout

  if [[ -n "$TARGET_URL" ]]; then
    export OPENCLAW_GATEWAY_URL="$TARGET_URL"
  fi
  if [[ -n "$TARGET_TOKEN" ]]; then
    export OPENCLAW_GATEWAY_TOKEN="$TARGET_TOKEN"
  fi

  load_checks_file "$CHECKS_FILE"
  load_legacy_checks

  if [[ ${#CHECK_SCOPE[@]} -eq 0 ]]; then
    if [[ "$REQUIRE_CHECKS" == "1" ]]; then
      log_line "$(integration_log "ERROR no integration checks configured")"
      append_event "integration-suite:${TARGET_NAME}" "error" "no checks configured"
      return 1
    fi
    log_line "$(integration_log "SKIP no integration checks configured")"
    append_event "integration-suite:${TARGET_NAME}" "skipped" "no checks configured"
    return 0
  fi

  local idx total pass fail
  local -a rows=()
  total=${#CHECK_SCOPE[@]}
  pass=0
  fail=0

  idx=0
  while (( idx < total )); do
    if run_check_retry "${CHECK_SCOPE[$idx]}" "${CHECK_NAME[$idx]}" "${CHECK_CMD[$idx]}"; then
      rows+=("${CHECK_SCOPE[$idx]} ${CHECK_NAME[$idx]} PASS")
      pass=$((pass + 1))
    else
      rows+=("${CHECK_SCOPE[$idx]} ${CHECK_NAME[$idx]} FAIL")
      fail=$((fail + 1))
    fi
    idx=$((idx + 1))
  done

  log_line "$(integration_log "MATRIX (scope name status)")"
  local row
  for row in "${rows[@]}"; do
    log_line "$(integration_log "$row")"
  done

  if (( fail > 0 )); then
    append_event "integration-suite:${TARGET_NAME}" "error" "pass=$pass fail=$fail"
    return 1
  fi

  append_event "integration-suite:${TARGET_NAME}" "ok" "pass=$pass fail=0"
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET_NAME="${2:-}"
      shift 2
      ;;
    --checks-file)
      CHECKS_FILE="${2:-}"
      shift 2
      ;;
    --require-checks)
      REQUIRE_CHECKS="${2:-0}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_line "$(integration_log "ERROR unknown argument: $1")"
      usage
      exit 2
      ;;
  esac
done

lock_target="$(event_safe "$TARGET_NAME")"
if with_lock "integration-suite-${lock_target}" main; then
  exit 0
fi

rc=$?
if [[ "$rc" -eq 99 ]]; then
  append_event "integration-suite:${TARGET_NAME}" "skipped" "lock-busy"
  exit 0
fi
exit "$rc"
