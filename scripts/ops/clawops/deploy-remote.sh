#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET=""
REMOTE_DIR="/opt/clawops"
INSTALL_TIMERS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="$2"
      shift 2
      ;;
    --remote-dir)
      REMOTE_DIR="$2"
      shift 2
      ;;
    --no-install-timers)
      INSTALL_TIMERS=0
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "missing --target user@host" >&2
  exit 2
fi

ssh "$TARGET" "mkdir -p '$REMOTE_DIR/scripts' '$REMOTE_DIR/systemd'"

rsync -az --delete "$SCRIPT_DIR/" "$TARGET:$REMOTE_DIR/scripts/"
rsync -az \
  "$SCRIPT_DIR/../../../scripts/systemd/clawops-release-watch.service" \
  "$SCRIPT_DIR/../../../scripts/systemd/clawops-release-watch.timer" \
  "$SCRIPT_DIR/../../../scripts/systemd/clawops-daily-digest.service" \
  "$SCRIPT_DIR/../../../scripts/systemd/clawops-daily-digest.timer" \
  "$SCRIPT_DIR/../../../scripts/systemd/clawops-weekly-hygiene.service" \
  "$SCRIPT_DIR/../../../scripts/systemd/clawops-weekly-hygiene.timer" \
  "$TARGET:$REMOTE_DIR/systemd/"

ssh "$TARGET" "chmod +x '$REMOTE_DIR/scripts/'*.sh"

if (( INSTALL_TIMERS == 1 )); then
  ssh "$TARGET" "bash -lc 'XDG_CONFIG_HOME=\$HOME/.config; mkdir -p \$HOME/.config/systemd/user; cp $REMOTE_DIR/systemd/clawops-* \$HOME/.config/systemd/user/; systemctl --user daemon-reload; systemctl --user enable --now clawops-release-watch.timer clawops-daily-digest.timer clawops-weekly-hygiene.timer'"
fi

echo "deployed clawops ops package to $TARGET:$REMOTE_DIR"
