#!/usr/bin/env bash
set -euo pipefail

# Codex Cloud setup is for repo work only. Production deploys stay on ACP/local Macs.
corepack enable
pnpm install --frozen-lockfile

# Keep setup fast and cacheable. Run validation inside tasks when needed:
#   pnpm check
#   OPENCLAW_TEST_PROFILE=low OPENCLAW_TEST_SERIAL_GATEWAY=1 pnpm test
#   bash -n scripts/ops/clawops/docker-image-rollout.sh
