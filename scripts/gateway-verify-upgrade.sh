#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_JSON="$ROOT_DIR/.agents/runbooks/openclaw-live-state.json"

if [ ! -f "$STATE_JSON" ]; then
  echo "Missing live-state manifest: $STATE_JSON" >&2
  exit 1
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd jq
require_cmd ssh
require_cmd curl
require_cmd base64

SSH_TARGET="$(jq -r '.sshTarget // empty' "$STATE_JSON")"
EXPECTED_VERSION="$(jq -r '.runtimeVersion // empty' "$STATE_JSON")"
REQUIRE_APPROVAL_TEXT_FALLBACK=0
SKIP_TOOLS=0
SURFACE_FILTERS=()
SSH_OPTS=(-n -o BatchMode=yes -o ConnectTimeout=8)

usage() {
  cat <<EOF
Usage: scripts/gateway-verify-upgrade.sh [options]

Options:
  --host <ssh-target>                  Override SSH target (default: manifest sshTarget)
  --surface <id>                       Verify only one surface (repeatable)
  --expected-version <version>         Override expected runtime version
  --skip-tools                         Skip HTTP tool smokes
  --require-approval-text-fallback     Fail if the no-ID /approve text fallback is missing
  --help                               Show this help

Examples:
  scripts/gateway-verify-upgrade.sh
  scripts/gateway-verify-upgrade.sh --surface clawops --surface main
  scripts/gateway-verify-upgrade.sh --host sreeopsadmin@10.108.0.2 --require-approval-text-fallback
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      SSH_TARGET="${2:-}"
      shift 2
      ;;
    --surface)
      SURFACE_FILTERS+=("${2:-}")
      shift 2
      ;;
    --expected-version)
      EXPECTED_VERSION="${2:-}"
      shift 2
      ;;
    --skip-tools)
      SKIP_TOOLS=1
      shift
      ;;
    --require-approval-text-fallback)
      REQUIRE_APPROVAL_TEXT_FALLBACK=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "$SSH_TARGET" ]; then
  echo "No SSH target configured. Set it in $STATE_JSON or pass --host." >&2
  exit 1
fi

surface_selected() {
  local wanted="$1"
  local item
  if [ "${#SURFACE_FILTERS[@]}" -eq 0 ]; then
    return 0
  fi
  for item in "${SURFACE_FILTERS[@]}"; do
    if [ "$item" = "$wanted" ]; then
      return 0
    fi
  done
  return 1
}

run_remote() {
  local cmd="$1"
  local quoted
  printf -v quoted '%q' "$cmd"
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "bash -lc $quoted"
}

note_pass() {
  printf '  [ok] %s\n' "$1"
}

note_info() {
  printf '  [..] %s\n' "$1"
}

note_fail() {
  printf '  [!!] %s\n' "$1"
}

json_compact() {
  jq -c '.' <<<"$1"
}

tool_payload() {
  case "$1" in
    web_search)
      printf '%s' '{"tool":"web_search","args":{"query":"OpenClaw","count":1}}'
      ;;
    x_search)
      printf '%s' '{"tool":"x_search","args":{"query":"OpenAI","count":10}}'
      ;;
    browser)
      printf '%s' '{"tool":"browser","args":{"action":"status"}}'
      ;;
    *)
      return 1
      ;;
  esac
}

tool_summary() {
  local tool="$1"
  local json="$2"
  case "$tool" in
    web_search)
      jq -r '.result.details.provider // "ok"' <<<"$json"
      ;;
    x_search)
      jq -r '"tweets=" + (((.result.details.tweets | length) // 0) | tostring)' <<<"$json"
      ;;
    browser)
      jq -r '"running=" + ((.result.details.running // false) | tostring)' <<<"$json"
      ;;
    *)
      jq -r '.ok | tostring' <<<"$json"
      ;;
  esac
}

detect_browser_binary() {
  local container="$1"
  local expected_path="${2:-}"
  local quoted_path
  printf -v quoted_path '%q' "$expected_path"
  run_remote "
expected_path=$quoted_path
sudo docker exec -e EXPECTED_BROWSER_PATH=\"\$expected_path\" '$container' sh -lc '
if [ -n \"\$EXPECTED_BROWSER_PATH\" ] && [ -e \"\$EXPECTED_BROWSER_PATH\" ]; then
  printf \"%s\n\" \"\$EXPECTED_BROWSER_PATH\"
  exit 0
fi
for candidate in chromium chromium-browser google-chrome google-chrome-stable brave-browser microsoft-edge msedge; do
  if command -v \"\$candidate\" >/dev/null 2>&1; then
    command -v \"\$candidate\"
    exit 0
  fi
done
exit 1
'
"
}

invoke_tool() {
  local config_path="$1"
  local payload="$2"
  local payload_b64
  payload_b64="$(printf '%s' "$payload" | base64 | tr -d '\n')"
  run_remote "
config_path=$(printf '%q' "$config_path")
payload_b64=$(printf '%q' "$payload_b64")
port=\$(sudo jq -r '.gateway.port' \"\$config_path\")
secret=\$(sudo jq -r '.gateway.auth.token // .gateway.auth.password // empty' \"\$config_path\")
if [ -z \"\$secret\" ] || [ \"\$secret\" = \"null\" ]; then
  echo '{\"ok\":false,\"error\":{\"message\":\"missing gateway auth secret\"}}'
  exit 0
fi
body=\$(printf '%s' \"\$payload_b64\" | base64 -d)
curl -sS \
  -H \"Authorization: Bearer \$secret\" \
  -H 'Content-Type: application/json' \
  -d \"\$body\" \
  \"http://127.0.0.1:\${port}/tools/invoke\"
"
}

TOTAL_SURFACES=0
PASSED_SURFACES=0
FAILURES=0

printf 'Gateway verify host=%s expectedVersion=%s\n' "$SSH_TARGET" "${EXPECTED_VERSION:-<report-only>}"
printf 'Manifest: %s\n' "$STATE_JSON"

SURFACES_JSON="$(jq -c '.surfaces[]' "$STATE_JSON")"
while IFS= read -r surface; do
  [ -n "$surface" ] || continue

  id="$(jq -r '.id' <<<"$surface")"
  if ! surface_selected "$id"; then
    continue
  fi

  TOTAL_SURFACES=$((TOTAL_SURFACES + 1))
  surface_failed=0

  container="$(jq -r '.container' <<<"$surface")"
  config_path="$(jq -r '.configPath' <<<"$surface")"
  expected_image="$(jq -r '.expectedImage // empty' <<<"$surface")"
  surface_expected_version="$(jq -r '.runtimeVersion // empty' <<<"$surface")"
  expected_target="$(jq -r '.telegramExecApprovals.target // empty' <<<"$surface")"
  approvals_required="$(jq -r '.telegramExecApprovals.required // false' <<<"$surface")"
  approval_count_expected="$(jq -r '(.telegramExecApprovals.approvers // []) | length' <<<"$surface")"
  browser_smoke="$(jq -r '.browserSmoke // false' <<<"$surface")"
  tool_smokes="$(jq -r '.toolSmokes[]? // empty' <<<"$surface")"
  fallback_required="$(jq -r '.approvalTextFallback.required // false' <<<"$surface")"
  browser_expected_enabled="$(jq -r 'if (.browser | type) == "object" and (.browser | has("expectedEnabled")) then (.browser.expectedEnabled | tostring) else empty end' <<<"$surface")"
  browser_require_explicit="$(jq -r '.browser.requireExplicitEnabled // false' <<<"$surface")"
  browser_expected_path="$(jq -r '.browser.expectedExecutablePath // empty' <<<"$surface")"
  generic_forward_expected_enabled="$(jq -r 'if (.genericExecApprovalForwarding | type) == "object" and (.genericExecApprovalForwarding | has("expectedEnabled")) then (.genericExecApprovalForwarding.expectedEnabled | tostring) else empty end' <<<"$surface")"
  elevated_required="$(jq -r '.telegramElevated.required // false' <<<"$surface")"
  elevated_expected_enabled="$(jq -r 'if (.telegramElevated | type) == "object" and (.telegramElevated | has("expectedEnabled")) then (.telegramElevated.expectedEnabled | tostring) else empty end' <<<"$surface")"

  echo
  printf '== %s ==\n' "$id"
  note_info "container=$container config=$config_path"

  inspect_json="$(run_remote "sudo docker inspect '$container' 2>/dev/null | jq '.[0]'" || true)"
  if [ -z "$inspect_json" ] || [ "$inspect_json" = "null" ]; then
    note_fail "container not found"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  running_image="$(jq -r '.Config.Image // ""' <<<"$inspect_json")"
  state_status="$(jq -r '.State.Status // ""' <<<"$inspect_json")"
  health_status="$(jq -r '.State.Health.Status // "none"' <<<"$inspect_json")"
  if [ "$state_status" = "running" ]; then
    note_pass "state=$state_status health=$health_status"
  else
    note_fail "state=$state_status health=$health_status"
    surface_failed=1
  fi

  if [ -n "$expected_image" ]; then
    if [ "$running_image" = "$expected_image" ]; then
      note_pass "image=$running_image"
    else
      note_fail "image=$running_image expected=$expected_image"
      surface_failed=1
    fi
  else
    note_info "image=$running_image"
  fi

  runtime_version="$(run_remote "sudo docker exec '$container' node -p \"require('/app/package.json').version\"" || true)"
  runtime_version="${runtime_version##*$'\n'}"
  version_to_check="$EXPECTED_VERSION"
  if [ -n "$surface_expected_version" ]; then
    version_to_check="$surface_expected_version"
  fi
  if [ -n "$version_to_check" ]; then
    if [ "$runtime_version" = "$version_to_check" ]; then
      note_pass "runtime=$runtime_version"
    else
      note_fail "runtime=$runtime_version expected=$version_to_check"
      surface_failed=1
    fi
  else
    note_info "runtime=$runtime_version"
  fi

  memory_usage="$(run_remote "sudo docker stats --no-stream --format '{{.MemUsage}}' '$container'" || true)"
  memory_usage="${memory_usage%%$'\n'*}"
  if [ -n "$memory_usage" ]; then
    note_info "memory=$memory_usage"
  fi

  health_code="$(run_remote "
port=\$(sudo jq -r '.gateway.port' '$config_path')
curl -sS -o /dev/null -w '%{http_code}' \"http://127.0.0.1:\${port}/healthz\"
" || true)"
  health_code="${health_code%%$'\n'*}"
  if [ "$health_code" = "200" ]; then
    note_pass "healthz=$health_code"
  else
    note_fail "healthz=$health_code"
    surface_failed=1
  fi

  approvals_json="$(run_remote "sudo jq -c '.channels.telegram.execApprovals // {}' '$config_path'" || true)"
  if [ -z "$approvals_json" ]; then
    approvals_json='{}'
  fi
  approvals_enabled="$(jq -r '.enabled // false' <<<"$approvals_json")"
  approvals_target="$(jq -r '.target // empty' <<<"$approvals_json")"
  approvals_count="$(jq -r '(.approvers // []) | length' <<<"$approvals_json")"
  if [ "$approvals_required" = "true" ]; then
    if [ "$approvals_enabled" = "true" ] && [ "$approvals_target" = "$expected_target" ] && [ "$approvals_count" -ge "$approval_count_expected" ]; then
      note_pass "telegram execApprovals enabled target=$approvals_target approvers=$approvals_count"
    else
      note_fail "telegram execApprovals enabled=$approvals_enabled target=$approvals_target approvers=$approvals_count"
      surface_failed=1
    fi
  else
    note_info "telegram execApprovals enabled=$approvals_enabled target=$approvals_target approvers=$approvals_count"
  fi

  if [ -n "$generic_forward_expected_enabled" ]; then
    generic_forward_raw="$(run_remote "sudo jq -r 'if .approvals.exec.enabled == true then \"true\" elif .approvals.exec.enabled == false then \"false\" else \"<unset>\" end' '$config_path'" || true)"
    generic_forward_raw="${generic_forward_raw%%$'\n'*}"
    if [ "$generic_forward_expected_enabled" = "true" ]; then
      if [ "$generic_forward_raw" = "true" ]; then
        note_pass "approvals.exec.enabled=$generic_forward_raw"
      else
        note_fail "approvals.exec.enabled=$generic_forward_raw expected=true"
        surface_failed=1
      fi
    else
      if [ "$generic_forward_raw" = "true" ]; then
        if [ "$approvals_enabled" = "true" ]; then
          note_fail "approvals.exec.enabled=true conflicts with native Telegram execApprovals on this surface"
        else
          note_fail "approvals.exec.enabled=true expected off"
        fi
        surface_failed=1
      else
        note_pass "approvals.exec.enabled=$generic_forward_raw (expected off)"
      fi
    fi
  fi

  if [ -n "$browser_expected_enabled" ]; then
    browser_enabled_raw="$(run_remote "sudo jq -r 'if .browser.enabled == true then \"true\" elif .browser.enabled == false then \"false\" else \"<unset>\" end' '$config_path'" || true)"
    browser_enabled_raw="${browser_enabled_raw%%$'\n'*}"
    if [ "$browser_require_explicit" = "true" ] && [ "$browser_enabled_raw" = "<unset>" ]; then
      note_fail "browser.enabled is unset; require explicit ${browser_expected_enabled} on this surface"
      surface_failed=1
    elif [ "$browser_enabled_raw" = "$browser_expected_enabled" ]; then
      note_pass "browser.enabled=$browser_enabled_raw"
    else
      note_fail "browser.enabled=$browser_enabled_raw expected=$browser_expected_enabled"
      surface_failed=1
    fi
  fi

  if [ "$elevated_required" = "true" ]; then
    elevated_json="$(run_remote "sudo jq -c '.tools.elevated // {}' '$config_path'" || true)"
    if [ -z "$elevated_json" ]; then
      elevated_json='{}'
    fi
    elevated_enabled="$(jq -r 'if .enabled == true then "true" elif .enabled == false then "false" else "<unset>" end' <<<"$elevated_json")"
    elevated_allow_json="$(jq -c '.allowFrom.telegram // []' <<<"$elevated_json")"
    elevated_missing=()
    while IFS= read -r approver; do
      [ -n "$approver" ] || continue
      if ! jq -e --arg approver "$approver" '.[] | tostring | select(. == $approver)' <<<"$elevated_allow_json" >/dev/null; then
        elevated_missing+=("$approver")
      fi
    done <<<"$(jq -r '.telegramElevated.allowFrom[]? // empty' <<<"$surface")"
    if [ "$elevated_enabled" != "$elevated_expected_enabled" ]; then
      note_fail "tools.elevated.enabled=$elevated_enabled expected=$elevated_expected_enabled"
      surface_failed=1
    elif [ "${#elevated_missing[@]}" -ne 0 ]; then
      note_fail "tools.elevated.allowFrom.telegram missing=${elevated_missing[*]}"
      surface_failed=1
    else
      allow_count="$(jq -r 'length' <<<"$elevated_allow_json")"
      note_pass "tools.elevated enabled for telegram approvers=$allow_count"
    fi
  fi

  fallback_usage_present=0
  fallback_missing_latest_present=0
  if run_remote "sudo docker exec '$container' sh -lc 'grep -R -F -q \"Usage: /approve [id] allow-once|allow-always|deny\" /app/dist 2>/dev/null || grep -R -F -q \"Usage: /approve [id] allow-once|allow-always|deny\" /app/src 2>/dev/null'"; then
    fallback_usage_present=1
  fi
  if run_remote "sudo docker exec '$container' sh -lc 'grep -R -F -q \"No pending exec approval found for this session\" /app/dist 2>/dev/null || grep -R -F -q \"No pending exec approval found for this session\" /app/src 2>/dev/null'"; then
    fallback_missing_latest_present=1
  fi
  fallback_present=0
  if [ "$fallback_usage_present" -eq 1 ] && [ "$fallback_missing_latest_present" -eq 1 ]; then
    fallback_present=1
  fi
  if [ "$fallback_present" -eq 1 ]; then
    note_pass "telegram no-id /approve text fallback present"
  else
    if [ "$fallback_usage_present" -eq 1 ] || [ "$fallback_missing_latest_present" -eq 1 ]; then
      note_info "telegram approval fallback partially present"
    else
      note_info "telegram no-id /approve text fallback not present"
    fi
    if [ "$fallback_required" = "true" ] || [ "$REQUIRE_APPROVAL_TEXT_FALLBACK" -eq 1 ]; then
      note_fail "approval text fallback required but missing"
      surface_failed=1
    fi
  fi

  if [ "$SKIP_TOOLS" -ne 1 ]; then
    while IFS= read -r tool; do
      [ -n "$tool" ] || continue
      payload="$(tool_payload "$tool")"
      tool_json="$(invoke_tool "$config_path" "$payload" || true)"
      if [ -z "$tool_json" ]; then
        note_fail "tool $tool returned no response"
        surface_failed=1
        continue
      fi
      if [ "$(jq -r '.ok // false' <<<"$tool_json")" = "true" ]; then
        note_pass "tool $tool $(tool_summary "$tool" "$tool_json")"
      else
        error_message="$(jq -r '.error.message // .result.details.error // "unknown error"' <<<"$tool_json")"
        note_fail "tool $tool failed: $error_message"
        surface_failed=1
      fi
    done <<<"$tool_smokes"
  else
    note_info "tool smokes skipped"
  fi

  if [ "$browser_smoke" = "true" ] && [ "$SKIP_TOOLS" -eq 1 ]; then
    note_info "browser smoke skipped with --skip-tools"
  fi

  if [ "$browser_smoke" = "true" ]; then
    browser_binary="$(detect_browser_binary "$container" "$browser_expected_path" || true)"
    browser_binary="${browser_binary%%$'\n'*}"
    if [ -n "$browser_binary" ]; then
      note_pass "browser binary=$browser_binary"
    else
      note_fail "browser binary missing inside container"
      surface_failed=1
    fi
  fi

  if [ "$surface_failed" -eq 0 ]; then
    PASSED_SURFACES=$((PASSED_SURFACES + 1))
  else
    FAILURES=$((FAILURES + 1))
  fi
done <<<"$SURFACES_JSON"

echo
printf 'Summary: %s/%s surfaces passed\n' "$PASSED_SURFACES" "$TOTAL_SURFACES"
if [ "$FAILURES" -ne 0 ]; then
  exit 1
fi
