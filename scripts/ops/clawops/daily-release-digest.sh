#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ops/clawops/lib.sh
source "$SCRIPT_DIR/lib.sh"

STATE_FILE="$(release_watch_state_file)"
CHANGELOG_URL="${CLAWOPS_CHANGELOG_URL:-https://raw.githubusercontent.com/openclaw/openclaw/main/CHANGELOG.md}"
CHANGELOG_LOCAL="${CLAWOPS_CHANGELOG_LOCAL:-}"

require_cmd jq
init_clawops_layout

ensure_release_watch_state_file "$STATE_FILE"

latest_version="$(jq -r '.lastSeenVersion // empty' "$STATE_FILE")"
if [[ -z "$latest_version" ]]; then
  log_line "WARN no seen release version yet"
  latest_version="unknown"
fi

canary_status="$(jq -r '.lastCanaryStatus // "unknown"' "$STATE_FILE")"

tmp_md="$(mktemp /tmp/clawops-changelog-XXXXXX)"
tmp_section="$(mktemp /tmp/clawops-changelog-section-XXXXXX)"
tmp_bullets="$(mktemp /tmp/clawops-changelog-bullets-XXXXXX)"

cleanup() {
  rm -f "$tmp_md" "$tmp_section" "$tmp_bullets"
}
trap cleanup EXIT

if [[ -n "$CHANGELOG_LOCAL" && -f "$CHANGELOG_LOCAL" ]]; then
  cp "$CHANGELOG_LOCAL" "$tmp_md"
elif [[ -f "CHANGELOG.md" ]]; then
  cp "CHANGELOG.md" "$tmp_md"
else
  curl -fsSL "$CHANGELOG_URL" -o "$tmp_md"
fi

if [[ "$latest_version" != "unknown" ]]; then
  awk -v ver="$latest_version" '
    BEGIN { in_section=0; found=0 }
    /^## / {
      if (in_section==1) { exit }
      if (index($0, ver) > 0) { in_section=1; found=1; print; next }
    }
    { if (in_section==1) print }
    END {
      if (found==0) {
        # no-op; caller handles empty output
      }
    }
  ' "$tmp_md" >"$tmp_section"
fi

if [[ ! -s "$tmp_section" ]]; then
  awk '
    BEGIN { in_section=0 }
    /^## / {
      if (in_section==1) { exit }
      in_section=1
      print
      next
    }
    { if (in_section==1) print }
  ' "$tmp_md" >"$tmp_section"
fi

grep -E '^- ' "$tmp_section" >"$tmp_bullets" || true

pick_category() {
  local name="$1"
  local pattern="$2"
  local hits
  hits="$(grep -E -i "$pattern" "$tmp_bullets" | head -n 3 | sed 's/^- //' || true)"
  if [[ -z "$hits" ]]; then
    printf -- '- %s: no key items found\n' "$name"
    return
  fi
  first=1
  while IFS= read -r line; do
    if (( first == 1 )); then
      printf -- '- %s: %s\n' "$name" "$line"
      first=0
    else
      printf -- '  + %s\n' "$line"
    fi
  done <<<"$hits"
}

summary_file="$(mktemp /tmp/clawops-digest-XXXXXX)"
{
  printf 'OpenClaw daily release digest (%s)\n' "$(date -u +%Y-%m-%d)"
  printf 'latest seen version: %s\n' "$latest_version"
  printf 'canary status: %s\n' "$canary_status"
  printf '\n'
  printf 'Workflow highlights:\n'
  pick_category "gateway/channels" 'gateway|channel|telegram|discord|whatsapp|slack|signal|matrix|msteams|zalo|feishu|imessage|routing'
  pick_category "PDF" 'pdf'
  pick_category "playwright/browser" 'playwright|browser|cdp|snapshot|screenshot|chrom'
  pick_category "himalaya/gmail/auth" 'himalaya|gmail|imap|smtp|auth|credential|token|notion'
  pick_category "deploy/runtime stability" 'deploy|release|update|memory|oom|crash|stability|reconnect|health|runtime'
} >"$summary_file"

notify_operator "$(cat "$summary_file")"
append_event "daily-release-digest" "ok" "version=$latest_version canary=$canary_status"

now_date="$(date -u +%Y-%m-%d)"
state_update_json_locked \
  "$STATE_FILE" \
  "release-watch-state" \
  '. + {lastDigestDate:$d}' \
  --arg d "$now_date"

rm -f "$summary_file"
