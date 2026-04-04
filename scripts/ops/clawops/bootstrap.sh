#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="/opt/clawops"
TARGET=""
INSTALL_TIMERS=1
RUN_SMOKE=1
RUN_WEEKLY=1
RUN_RELEASE_WATCH=1
RECORD_DRIFT_BASELINE=1
STRICT_SECRETS=1
SOURCE_ENV=1

usage() {
  cat <<'USAGE'
Usage:
  scripts/ops/clawops/bootstrap.sh [options]

Options:
  --target user@host         Deploy + bootstrap on remote host over SSH.
  --remote-dir PATH          Remote install root (default: /opt/clawops).
  --no-install-timers        Skip timer installation/enabling.
  --skip-smoke               Skip smoke suite.
  --skip-weekly              Skip weekly hygiene one-shot.
  --skip-release-watch       Skip immediate release-watch one-shot.
  --no-record-drift-baseline Skip initial drift baseline recording.
  --no-strict-secrets        Do not fail bootstrap on missing required secrets.
  --no-source-env            Do not source <remote-dir>/.env before running.
  -h, --help                 Show this help text.
USAGE
}

log() {
  printf '[bootstrap] %s\n' "$*"
}

run_local() {
  local validate_args=()
  local validate_followup_args=()

  if (( STRICT_SECRETS == 0 )); then
    validate_args+=(--no-strict-secrets)
    validate_followup_args+=(--no-strict-secrets)
  fi

  if (( SOURCE_ENV == 1 )) && [[ -f /opt/clawops/.env ]]; then
    # shellcheck disable=SC1091
    set -a && . /opt/clawops/.env && set +a
    log "sourced /opt/clawops/.env"
  fi

  log "applying baseline"
  "$SCRIPT_DIR/apply-baseline.sh"

  if (( RECORD_DRIFT_BASELINE == 1 )); then
    log "recording drift baseline"
    "$SCRIPT_DIR/validate-runtime.sh" --record-drift-baseline "${validate_args[@]}"
  fi

  log "validating runtime"
  "$SCRIPT_DIR/validate-runtime.sh" "${validate_followup_args[@]}"

  if (( INSTALL_TIMERS == 1 )); then
    log "installing systemd user timers"
    "$SCRIPT_DIR/install-systemd.sh"
  fi

  if (( RUN_RELEASE_WATCH == 1 )); then
    log "running release-watch one-shot"
    "$SCRIPT_DIR/release-watch.sh"
  fi

  if (( RUN_SMOKE == 1 )); then
    log "running smoke suite"
    "$SCRIPT_DIR/smoke-suite.sh"
  fi

  if (( RUN_WEEKLY == 1 )); then
    log "running weekly hygiene one-shot"
    "$SCRIPT_DIR/weekly-hygiene.sh"
  fi

  log "bootstrap completed"
}

run_remote() {
  local deploy_args=(
    --target "$TARGET"
    --remote-dir "$REMOTE_DIR"
  )
  local remote_validate_args=""
  local source_env_cmd=""
  local remote_script=""
  local ssh_payload=""

  if (( INSTALL_TIMERS == 0 )); then
    deploy_args+=(--no-install-timers)
  fi

  if (( STRICT_SECRETS == 0 )); then
    remote_validate_args="--no-strict-secrets"
  fi

  if (( SOURCE_ENV == 1 )); then
    source_env_cmd="set -a; [ -f \"$REMOTE_DIR/.env\" ] && . \"$REMOTE_DIR/.env\"; set +a;"
  fi

  log "deploying package to $TARGET:$REMOTE_DIR"
  "$SCRIPT_DIR/deploy-remote.sh" "${deploy_args[@]}"

  remote_script="set -euo pipefail;"
  if [[ -n "$source_env_cmd" ]]; then
    remote_script+="$source_env_cmd"
  fi
  remote_script+="$REMOTE_DIR/scripts/apply-baseline.sh;"

  if (( RECORD_DRIFT_BASELINE == 1 )); then
    remote_script+="$REMOTE_DIR/scripts/validate-runtime.sh --record-drift-baseline $remote_validate_args;"
  fi

  remote_script+="$REMOTE_DIR/scripts/validate-runtime.sh $remote_validate_args;"

  if (( RUN_RELEASE_WATCH == 1 )); then
    remote_script+="$REMOTE_DIR/scripts/release-watch.sh;"
  fi

  if (( RUN_SMOKE == 1 )); then
    remote_script+="$REMOTE_DIR/scripts/smoke-suite.sh;"
  fi

  if (( RUN_WEEKLY == 1 )); then
    remote_script+="$REMOTE_DIR/scripts/weekly-hygiene.sh;"
  fi

  remote_script+="echo '[bootstrap] remote bootstrap completed';"
  ssh_payload="$(printf '%q' "$remote_script")"

  log "running bootstrap workflow on remote host"
  ssh "$TARGET" "bash -lc $ssh_payload"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --remote-dir)
      REMOTE_DIR="${2:-}"
      shift 2
      ;;
    --no-install-timers)
      INSTALL_TIMERS=0
      shift
      ;;
    --skip-smoke)
      RUN_SMOKE=0
      shift
      ;;
    --skip-weekly)
      RUN_WEEKLY=0
      shift
      ;;
    --skip-release-watch)
      RUN_RELEASE_WATCH=0
      shift
      ;;
    --no-record-drift-baseline)
      RECORD_DRIFT_BASELINE=0
      shift
      ;;
    --no-strict-secrets)
      STRICT_SECRETS=0
      shift
      ;;
    --no-source-env)
      SOURCE_ENV=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -n "$TARGET" ]]; then
  run_remote
else
  run_local
fi
