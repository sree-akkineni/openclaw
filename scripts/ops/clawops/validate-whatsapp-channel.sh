#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ops/clawops/lib.sh
source "$SCRIPT_DIR/lib.sh"

MODE="twilio-voice-sms"
ENV_FILE="${CLAWOPS_ENV_FILE:-/opt/clawops/.env}"
SKIP_CHANNEL_PROBE=0
STATUS_FILE=""

usage() {
  cat <<'USAGE'
Usage:
  validate-whatsapp-channel.sh [options]

Options:
  --mode <twilio-voice-sms|whatsapp-web>  Validation mode (default: twilio-voice-sms)
  --env-file <path>                       Environment file to read (default: /opt/clawops/.env)
  --skip-channel-probe                    Skip live channel probe parsing
  --status-file <path>                    Parse probe output from file instead of live openclaw call
  --help                                  Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --skip-channel-probe)
      SKIP_CHANNEL_PROBE=1
      shift
      ;;
    --status-file)
      STATUS_FILE="${2:-}"
      shift 2
      ;;
    --help|-h)
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

if [[ "$MODE" != "twilio-voice-sms" && "$MODE" != "whatsapp-web" ]]; then
  log_line "ERROR unsupported mode: $MODE"
  usage
  exit 2
fi

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

failures=0
probe_output=""

mark_ok() {
  log_line "OK $1"
}

mark_error() {
  log_line "ERROR $1"
  failures=1
}

has_secret() {
  local key="$1"
  if [[ -n "${!key:-}" ]]; then
    return 0
  fi
  if [[ -f "$ENV_FILE" ]] && grep -Eq "^[[:space:]]*${key}=" "$ENV_FILE"; then
    return 0
  fi
  return 1
}

require_secret() {
  local key="$1"
  if has_secret "$key"; then
    mark_ok "required secret present: $key"
  else
    mark_error "missing required secret: $key"
  fi
}

load_probe_output() {
  if (( SKIP_CHANNEL_PROBE == 1 )); then
    mark_ok "channel probe skipped by flag"
    return 0
  fi

  if [[ -n "$STATUS_FILE" ]]; then
    if [[ ! -f "$STATUS_FILE" ]]; then
      mark_error "status file not found: $STATUS_FILE"
      return 1
    fi
    probe_output="$(cat "$STATUS_FILE")"
    mark_ok "loaded channel probe output from status file"
    return 0
  fi

  if ! command -v openclaw >/dev/null 2>&1; then
    mark_error "openclaw CLI not found; use --status-file or --skip-channel-probe"
    return 1
  fi

  if probe_output="$(openclaw channels status --probe 2>&1)"; then
    mark_ok "openclaw channels status --probe"
    return 0
  fi

  mark_error "openclaw channels status --probe failed"
  return 1
}

probe_contains() {
  local pattern="$1"
  if printf '%s\n' "$probe_output" | grep -Eiq "$pattern"; then
    return 0
  fi
  return 1
}

validate_twilio_voice_sms() {
  require_secret "TWILIO_ACCOUNT_SID"
  require_secret "TWILIO_AUTH_TOKEN"
  require_secret "TWILIO_FROM_NUMBER"

  if (( SKIP_CHANNEL_PROBE == 0 )); then
    if probe_contains 'twilio|voice[-_ ]?call|sms'; then
      mark_ok "channel probe includes Twilio voice/SMS surface"
    else
      mark_error "channel probe does not show Twilio voice/SMS surface"
    fi
  fi
}

validate_whatsapp_web() {
  if (( SKIP_CHANNEL_PROBE == 1 )); then
    mark_error "whatsapp-web mode requires a channel probe (remove --skip-channel-probe)"
    return
  fi

  if probe_contains 'whatsapp'; then
    mark_ok "channel probe includes WhatsApp surface"
  else
    mark_error "channel probe does not show WhatsApp surface"
  fi

  if probe_contains 'not linked|unlinked|scan qr|qr code'; then
    mark_error "WhatsApp appears unlinked; complete dedicated-account QR linking"
  else
    mark_ok "WhatsApp appears linked"
  fi
}

init_clawops_layout
load_probe_output || true

case "$MODE" in
  twilio-voice-sms)
    validate_twilio_voice_sms
    ;;
  whatsapp-web)
    validate_whatsapp_web
    ;;
esac

if (( failures > 0 )); then
  append_event "channel-validate:$MODE" "error" "channel validation failed"
  notify_operator "channel validation failed mode=$MODE"
  exit 1
fi

append_event "channel-validate:$MODE" "ok" "channel validation passed"
notify_operator "channel validation passed mode=$MODE"
log_line "channel validation passed mode=$MODE"
