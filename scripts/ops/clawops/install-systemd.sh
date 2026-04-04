#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SYSTEMD_SRC="$REPO_ROOT/scripts/systemd"
TARGET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

mkdir -p "$TARGET_DIR"

units=(
  clawops-release-watch.service
  clawops-release-watch.timer
  clawops-daily-digest.service
  clawops-daily-digest.timer
  clawops-weekly-hygiene.service
  clawops-weekly-hygiene.timer
)

for u in "${units[@]}"; do
  install -m 644 "$SYSTEMD_SRC/$u" "$TARGET_DIR/$u"
done

systemctl --user daemon-reload
systemctl --user enable --now \
  clawops-release-watch.timer \
  clawops-daily-digest.timer \
  clawops-weekly-hygiene.timer

echo "Installed and enabled clawops timers in $TARGET_DIR"
