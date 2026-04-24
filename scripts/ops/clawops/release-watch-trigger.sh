#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ops/clawops/lib.sh
source "$SCRIPT_DIR/lib.sh"

VERSION=""
PAYLOAD_FILE=""
FORCE_CANARY=0

usage() {
  cat <<'USAGE'
Usage:
  release-watch-trigger.sh [--version X.Y.Z] [--payload-file /path/to/event.json] [--force-canary]

Examples:
  release-watch-trigger.sh --version 2026.4.1
  release-watch-trigger.sh --payload-file /tmp/release-event.json
  curl -sS https://example/webhook | release-watch-trigger.sh --force-canary
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --payload-file)
      PAYLOAD_FILE="${2:-}"
      shift 2
      ;;
    --force-canary)
      FORCE_CANARY=1
      shift
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

extract_version_from_payload() {
  local payload="$1"
  if [[ -z "$payload" || "$payload" == "{}" ]]; then
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi

  jq -r '
    .version //
    .release.version //
    .data.version //
    .payload.version //
    empty
  ' <<<"$payload" | head -n 1
}

if [[ -z "$VERSION" ]]; then
  payload_json=""
  if [[ -n "$PAYLOAD_FILE" ]]; then
    payload_json="$(cat "$PAYLOAD_FILE" 2>/dev/null || true)"
  elif ! test -t 0; then
    payload_json="$(cat || true)"
  fi
  VERSION="$(extract_version_from_payload "$payload_json" || true)"
fi

export CLAWOPS_RELEASE_TRIGGER_MODE="webhook"
if [[ -n "$VERSION" ]]; then
  export CLAWOPS_RELEASE_WEBHOOK_VERSION="$VERSION"
fi
if [[ "$FORCE_CANARY" == "1" ]]; then
  export CLAWOPS_WEBHOOK_FORCE_CANARY="1"
fi

log_line "release webhook trigger mode activated version=${VERSION:-auto} forceCanary=$FORCE_CANARY"
exec "$SCRIPT_DIR/release-watch.sh" --trigger-mode webhook --forced-version "${VERSION:-}" --webhook-force-canary "$FORCE_CANARY"
