#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ops/clawops/lib.sh
source "$SCRIPT_DIR/lib.sh"

RECORD_DRIFT_BASELINE=0
STRICT_SECRETS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --record-drift-baseline)
      RECORD_DRIFT_BASELINE=1
      shift
      ;;
    --no-strict-secrets)
      STRICT_SECRETS=0
      shift
      ;;
    *)
      log_line "ERROR unknown argument: $1"
      exit 2
      ;;
  esac
done

init_clawops_layout

failures=0

norm() {
  tr -d '"' | tr -d '[:space:]'
}

check_eq() {
  local key="$1"
  local expected="$2"
  local got
  got="$(openclaw config get "$key" 2>/dev/null | norm || true)"
  if [[ "$got" != "$expected" ]]; then
    log_line "ERROR config mismatch $key expected=$expected got=${got:-<empty>}"
    failures=1
  else
    log_line "OK $key=$expected"
  fi
}

check_in_set() {
  local key="$1"
  shift
  local -a allowed=("$@")
  local got
  got="$(openclaw config get "$key" 2>/dev/null | norm || true)"
  local item
  for item in "${allowed[@]}"; do
    if [[ "$got" == "$item" ]]; then
      log_line "OK $key=$got"
      return 0
    fi
  done
  log_line "ERROR config mismatch $key expected one of=[${allowed[*]}] got=${got:-<empty>}"
  failures=1
}

if [[ -f "$CLAWOPS_LOCKFILE" ]]; then
  if ! baseline_lock_verify "$CLAWOPS_LOCKFILE"; then
    failures=1
  else
    log_line "OK baseline lock verified"
  fi
else
  log_line "WARN baseline lock file missing: $CLAWOPS_LOCKFILE"
  failures=1
fi

if command -v openclaw >/dev/null 2>&1; then
  if ! openclaw config validate >/dev/null 2>&1; then
    log_line "ERROR openclaw config validate failed"
    failures=1
  else
    log_line "OK openclaw config validate"
  fi

  check_eq "tools.exec.host" "gateway"
  check_eq "tools.exec.security" "full"
  check_eq "tools.exec.ask" "off"
  check_eq "acp.enabled" "true"
  check_eq "session.threadBindings.enabled" "true"
  check_eq "channels.telegram.execApprovals.enabled" "true"
  check_in_set "channels.telegram.execApprovals.target" "channel" "both"

  deny="$(openclaw config get tools.deny 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "$deny" == *"cron"* ]]; then
    log_line "ERROR tools.deny still includes cron"
    failures=1
  else
    log_line "OK cron tool allowed"
  fi

  heartbeat_every="$(openclaw config get agents.defaults.heartbeat.every 2>/dev/null | norm || true)"
  if [[ -z "$heartbeat_every" ]]; then
    log_line "ERROR missing agents.defaults.heartbeat.every"
    failures=1
  else
    log_line "OK heartbeat cadence set: $heartbeat_every"
  fi
else
  log_line "WARN openclaw CLI not found; skipping live config checks"
fi

env_has_key() {
  local key="$1"
  if [[ -n "${!key:-}" ]]; then
    return 0
  fi
  if [[ -f "$HOME/.openclaw/.env" ]] && grep -q "^${key}=" "$HOME/.openclaw/.env"; then
    return 0
  fi
  return 1
}

notify_mode="${CLAWOPS_NOTIFY_MODE:-message}"
if [[ "$notify_mode" == "session" ]]; then
  if env_has_key "CLAWOPS_NOTIFY_SESSION_KEY"; then
    log_line "OK notify session key present for cron session targeting"
  else
    log_line "ERROR CLAWOPS_NOTIFY_MODE=session but CLAWOPS_NOTIFY_SESSION_KEY is missing"
    failures=1
  fi
fi

if env_has_key "CLAWOPS_WEBHOOK_URL"; then
  if command -v curl >/dev/null 2>&1; then
    log_line "OK webhook trigger mode prerequisites present (CLAWOPS_WEBHOOK_URL + curl)"
  else
    log_line "ERROR CLAWOPS_WEBHOOK_URL set but curl is missing"
    failures=1
  fi
fi

required_secrets="${CLAWOPS_REQUIRED_SECRETS-NOTION_API_KEY,HIMALAYA_PASSWORD,GMAIL_APP_PASSWORD}"
if [[ -n "$required_secrets" ]]; then
  IFS=',' read -r -a keys <<<"$required_secrets"
  for key in "${keys[@]}"; do
    key="${key//[[:space:]]/}"
    [[ -z "$key" ]] && continue

    have=0
    if [[ -n "${!key:-}" ]]; then
      have=1
    elif [[ -f "$HOME/.openclaw/.env" ]] && grep -q "^${key}=" "$HOME/.openclaw/.env"; then
      have=1
    fi

    if (( have == 0 )); then
      log_line "ERROR missing required secret: $key"
      if (( STRICT_SECRETS == 1 )); then
        failures=1
      fi
    else
      log_line "OK required secret present: $key"
    fi
  done
fi

drift_lock="$CLAWOPS_STATE_DIR/drift-watch.lock"
drift_watch="${CLAWOPS_DRIFT_WATCH_FILES:-/opt/remy-bot/docker-compose.override.yml,/opt/openclaw-docker/docker-compose.override.yml,/opt/gumnut/docker-compose.override.yml}"

if [[ -n "$drift_watch" ]]; then
  if (( RECORD_DRIFT_BASELINE == 1 )); then
    : >"$drift_lock"
    IFS=',' read -r -a files <<<"$drift_watch"
    for f in "${files[@]}"; do
      f="${f//[[:space:]]/}"
      [[ -z "$f" ]] && continue
      if [[ -f "$f" ]]; then
        printf '%s|%s\n' "$f" "$(sha256_file "$f")" >>"$drift_lock"
      fi
    done
    log_line "drift baseline recorded: $drift_lock"
  elif [[ -f "$drift_lock" ]]; then
    while IFS='|' read -r f expected; do
      [[ -z "$f" ]] && continue
      if [[ ! -f "$f" ]]; then
        log_line "ERROR drift watch missing file: $f"
        failures=1
        continue
      fi
      actual="$(sha256_file "$f")"
      if [[ "$actual" != "$expected" ]]; then
        log_line "ERROR drift watch mismatch: $f"
        failures=1
      fi
    done <"$drift_lock"
  else
    log_line "WARN drift baseline lock missing: $drift_lock"
  fi
fi

if (( failures > 0 )); then
  append_event "runtime-validate" "error" "failures=$failures"
  notify_operator "runtime validation failed (failures=$failures)"
  exit 1
fi

append_event "runtime-validate" "ok" "all checks passed"
log_line "runtime validation passed"
