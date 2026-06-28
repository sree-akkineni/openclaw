#!/usr/bin/env bash
set -euo pipefail

TARGET_VERSION=""
TARGETS="clawops,shibot,gumnut,remy"
CANARY_TARGET="clawops"
REMOTE_HOST=""
REMOTE_DIR="/opt/clawops"
ROLLBACK_VERSION=""
SKIP_ROLLOUT=0

usage() {
  cat <<'USAGE'
Usage:
  docker-image-rollout.sh --version VERSION [options]

Options:
  --version VERSION          Required OpenClaw image version, for example 2026.5.5.
  --targets a,b,c            Rollout order after canary. Default: clawops,shibot,gumnut,remy.
  --canary TARGET            Canary target. Default: clawops.
  --rollback-version VERSION Image version used for rollback notes. Optional.
  --remote HOST              Run against a remote host over ssh.
  --remote-dir DIR           Remote clawops dir for script context. Default: /opt/clawops.
  --skip-rollout             Run canary only.
  -h, --help                 Show this help text.

This script is intentionally Docker-image based. It does not run `openclaw update`
inside a container because these deployments are compose-managed by image tag.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      TARGET_VERSION="${2:-}"
      shift 2
      ;;
    --targets)
      TARGETS="${2:-}"
      shift 2
      ;;
    --canary)
      CANARY_TARGET="${2:-}"
      shift 2
      ;;
    --rollback-version)
      ROLLBACK_VERSION="${2:-}"
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
    --skip-rollout)
      SKIP_ROLLOUT=1
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

if [[ -z "$TARGET_VERSION" ]]; then
  echo "ERROR --version is required" >&2
  usage >&2
  exit 2
fi

runner_payload() {
  cat <<'REMOTE_SCRIPT'
set -euo pipefail

TARGET_VERSION="__TARGET_VERSION__"
TARGETS="__TARGETS__"
CANARY_TARGET="__CANARY_TARGET__"
ROLLBACK_VERSION="__ROLLBACK_VERSION__"
SKIP_ROLLOUT="__SKIP_ROLLOUT__"
IMAGE="ghcr.io/openclaw/openclaw:${TARGET_VERSION}"

declare -A DIRS=(
  [clawops]="/opt/clawops"
  [shibot]="/opt/openclaw-docker"
  [gumnut]="/opt/gumnut-bot"
  [remy]="/opt/remy-bot"
)
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

backup_target() {
  local target="$1" dir stamp backup_dir
  dir="${DIRS[$target]}"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="$dir/backups/upgrade-$stamp"
  sudo mkdir -p "$backup_dir"
  sudo cp "$dir/docker-compose.yml" "$dir/.env" "$backup_dir/" 2>/dev/null || true
  if [[ -f "$dir/config/openclaw.json" ]]; then
    sudo cp "$dir/config/openclaw.json" "$backup_dir/" || true
  fi
  log "$target backup=$backup_dir"
}

set_image() {
  local target="$1" dir stamp
  dir="${DIRS[$target]}"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ -f "$dir/.env" ]] && sudo grep -q '^OPENCLAW_IMAGE=' "$dir/.env"; then
    sudo sed -i.bak-upgrade-$stamp "s#^OPENCLAW_IMAGE=.*#OPENCLAW_IMAGE=$IMAGE#" "$dir/.env"
  else
    printf 'OPENCLAW_IMAGE=%s\n' "$IMAGE" | sudo tee -a "$dir/.env" >/dev/null
  fi
}

wait_healthy() {
  local container="$1" status
  for _ in $(seq 1 60); do
    status="$(sudo docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
    log "$container health=$status"
    [[ "$status" == "healthy" || "$status" == "running" ]] && return 0
    sleep 3
  done
  return 1
}

upgrade_target() {
  local target="$1" dir container
  dir="${DIRS[$target]}"
  container="${CONTAINERS[$target]}"
  if [[ -z "${dir:-}" || -z "${container:-}" ]]; then
    log "ERROR unknown target: $target"
    return 2
  fi
  log "upgrade target=$target image=$IMAGE"
  backup_target "$target"
  set_image "$target"
  (cd "$dir" && sudo docker compose up -d --force-recreate)
  wait_healthy "$container"
}

check_target_common() {
  local target="$1" container
  container="${CONTAINERS[$target]}"
  log "check common target=$target"
  sudo docker exec -u root "$container" sh -lc 'openclaw --version; openclaw config validate; openclaw plugins doctor 2>&1 || true; himalaya --version 2>/dev/null | head -1 || true'
  sudo docker exec -u root "$container" sh -lc "openclaw agent --agent main --message 'Reply exactly STATUS=ok AGENT=$target VERSION=$TARGET_VERSION' --thinking low"
  sudo docker exec -u root "$container" sh -lc 'timeout 120 openclaw browser open https://example.com >/tmp/browser-open.out && timeout 120 openclaw browser snapshot | head -20'
}

check_clawops_canary() {
  log "check clawops local smoke"
  sudo docker exec -u root clawops-gateway sh -lc 'set -a; [ -f /opt/clawops/.env ] && . /opt/clawops/.env; set +a; unset CLAWOPS_TARGET_CLAWOPS_URL CLAWOPS_TARGET_CLAWOPS_TOKEN CLAWOPS_TARGET_CLAWOPS_INTEGRATION_CONTAINER; timeout 1500 /opt/clawops/scripts/smoke-suite.sh --targets local'
}

check_gumnut_duckbill() {
  log "check gumnut duckbill"
  sudo docker exec -u root gumnut-bot-gateway sh -lc 'openclaw agent --agent main --message "Use the duckbill tool with action inspect_tools and reply exactly STATUS=ok DUCKBILL=ok." --thinking low'
}

main() {
  sudo docker pull "$IMAGE"
  upgrade_target "$CANARY_TARGET"
  if [[ "$CANARY_TARGET" == "clawops" ]]; then
    check_clawops_canary
  else
    check_target_common "$CANARY_TARGET"
  fi

  if [[ "$SKIP_ROLLOUT" == "1" ]]; then
    log "canary-only complete version=$TARGET_VERSION rollbackVersion=${ROLLBACK_VERSION:-unset}"
    return 0
  fi

  local target
  while IFS= read -r target; do
    [[ -z "$target" || "$target" == "$CANARY_TARGET" ]] && continue
    upgrade_target "$target"
    check_target_common "$target"
    [[ "$target" == "gumnut" ]] && check_gumnut_duckbill
  done < <(split_targets "$TARGETS")

  log "rollout complete version=$TARGET_VERSION rollbackVersion=${ROLLBACK_VERSION:-unset}"
}

main "$@"
REMOTE_SCRIPT
}

payload="$(runner_payload)"
payload="${payload//__TARGET_VERSION__/$TARGET_VERSION}"
payload="${payload//__TARGETS__/$TARGETS}"
payload="${payload//__CANARY_TARGET__/$CANARY_TARGET}"
payload="${payload//__ROLLBACK_VERSION__/$ROLLBACK_VERSION}"
payload="${payload//__SKIP_ROLLOUT__/$SKIP_ROLLOUT}"

if [[ -n "$REMOTE_HOST" ]]; then
  printf '%s\n' "$payload" | ssh "$REMOTE_HOST" "cd '$REMOTE_DIR' 2>/dev/null || true; bash -s"
else
  printf '%s\n' "$payload" | bash -s
fi
