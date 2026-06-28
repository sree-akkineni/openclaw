#!/usr/bin/env bash
set -euo pipefail

TARGETS="clawops,shibot,gumnut,remy"
EXPECTED_VERSION=""
REMOTE_HOST=""
REMOTE_DIR="/opt/clawops"
WITH_CLAWOPS_SMOKE=0

usage() {
  cat <<'USAGE'
Usage:
  agent-container-qa.sh [options]

Options:
  --targets a,b,c            Targets to verify. Default: clawops,shibot,gumnut,remy.
  --expected-version VERSION Require `openclaw --version` to include this version.
  --remote HOST              Run against a remote host over ssh.
  --remote-dir DIR           Remote clawops dir for script context. Default: /opt/clawops.
  --with-clawops-smoke       Also run the full clawops local smoke suite.
  -h, --help                 Show this help text.

This harness runs checks inside each agent container. It intentionally avoids
host-IP gateway URLs because those produced false-negative timeouts during the
2026-05-06 Docker image rollout drill. Full clawops smoke is useful but slow,
so it is opt-in for post-upgrade sweeps.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --targets)
      TARGETS="${2:-}"
      shift 2
      ;;
    --expected-version)
      EXPECTED_VERSION="${2:-}"
      shift 2
      ;;
    --remote)
      REMOTE_HOST="${2:-}"
      shift 2
      ;;
    --remote-dir)
      REMOTE_DIR="${2:-}"
      shift 2
      ;;
    --with-clawops-smoke)
      WITH_CLAWOPS_SMOKE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

runner_payload() {
  cat <<'REMOTE_SCRIPT'
set -euo pipefail

TARGETS="__TARGETS__"
EXPECTED_VERSION="__EXPECTED_VERSION__"
WITH_CLAWOPS_SMOKE="__WITH_CLAWOPS_SMOKE__"

declare -A CONTAINERS=(
  [clawops]="clawops-gateway"
  [shibot]="openclaw-docker-openclaw-gateway-1"
  [gumnut]="gumnut-bot-gateway"
  [remy]="remy-bot-gateway"
)

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(ts)" "$*"; }

split_targets() {
  local raw="$1"
  raw="${raw//,/ }"
  printf '%s\n' $raw
}

container_health() {
  local container="$1"
  sudo docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true
}

check_version() {
  local target="$1" container="$2" version
  version="$(sudo docker exec -u root "$container" sh -lc 'openclaw --version' | tr -d '\r')"
  log "$target version=$version"
  if [[ -n "$EXPECTED_VERSION" && "$version" != *"$EXPECTED_VERSION"* ]]; then
    log "ERROR $target expected version containing $EXPECTED_VERSION"
    return 1
  fi
}

check_common() {
  local target="$1" container="$2" health
  health="$(container_health "$container")"
  log "$target container=$container health=$health"
  [[ "$health" == "healthy" || "$health" == "running" ]] || return 1

  check_version "$target" "$container"
  sudo docker exec -u root "$container" sh -lc 'openclaw config validate'
  sudo docker exec -u root "$container" sh -lc 'openclaw plugins doctor 2>&1 || true'
  sudo docker exec -u root "$container" sh -lc 'command -v himalaya >/dev/null && himalaya --version 2>/dev/null | head -1 || true'
  sudo docker exec -u root "$container" sh -lc "openclaw agent --agent main --message 'Reply exactly STATUS=ok AGENT=$target' --thinking low | grep -q 'STATUS=ok'"
  sudo docker exec -u root "$container" sh -lc 'openclaw browser stop >/dev/null 2>&1 || true; trap "openclaw browser stop >/dev/null 2>&1 || true" EXIT; timeout 120 openclaw browser open https://example.com >/tmp/browser-open.out && timeout 120 openclaw browser snapshot >/tmp/browser-snapshot.out && test -s /tmp/browser-snapshot.out'
}

check_clawops() {
  log "clawops local smoke suite"
  sudo docker exec -u root clawops-gateway sh -lc 'set -a; [ -f /opt/clawops/.env ] && . /opt/clawops/.env; set +a; unset CLAWOPS_TARGET_CLAWOPS_URL CLAWOPS_TARGET_CLAWOPS_TOKEN CLAWOPS_TARGET_CLAWOPS_INTEGRATION_CONTAINER; timeout 1500 /opt/clawops/scripts/smoke-suite.sh --targets local'
}

check_gumnut_duckbill() {
  log "gumnut duckbill smoke"
  sudo docker exec -u root gumnut-bot-gateway sh -lc 'openclaw agent --agent main --message "Use the duckbill tool with action inspect_tools and reply exactly STATUS=ok DUCKBILL=ok." --thinking low | grep -q "STATUS=ok"'
}

main() {
  local failures=0 target container
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    container="${CONTAINERS[$target]:-}"
    if [[ -z "$container" ]]; then
      log "ERROR unknown target=$target"
      failures=$((failures + 1))
      continue
    fi

    log "QA target=$target"
    if check_common "$target" "$container"; then
      if [[ "$target" == "clawops" && "$WITH_CLAWOPS_SMOKE" == "1" ]]; then
        check_clawops || failures=$((failures + 1))
      fi
      if [[ "$target" == "gumnut" ]]; then
        check_gumnut_duckbill || failures=$((failures + 1))
      fi
      log "QA target=$target PASS"
    else
      log "QA target=$target FAIL"
      failures=$((failures + 1))
    fi
  done < <(split_targets "$TARGETS")

  if (( failures > 0 )); then
    log "QA complete FAIL failures=$failures"
    return 1
  fi
  log "QA complete PASS"
}

main "$@"
REMOTE_SCRIPT
}

payload="$(runner_payload)"
payload="${payload//__TARGETS__/$TARGETS}"
payload="${payload//__EXPECTED_VERSION__/$EXPECTED_VERSION}"
payload="${payload//__WITH_CLAWOPS_SMOKE__/$WITH_CLAWOPS_SMOKE}"

if [[ -n "$REMOTE_HOST" ]]; then
  printf '%s\n' "$payload" | ssh "$REMOTE_HOST" "cd '$REMOTE_DIR' 2>/dev/null || true; bash -s"
else
  printf '%s\n' "$payload" | bash -s
fi
