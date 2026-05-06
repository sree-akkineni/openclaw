# OpenClaw Docker Upgrade Notes (2026-05-06)

## Summary

- Latest stable checked from npm: `2026.5.5`.
- Production Docker image used: `ghcr.io/openclaw/openclaw:2026.5.5`.
- Prior stable baseline before this pass: `2026.5.3-1`.
- Canary target: `clawops-gateway`.
- Rollout order used after canary: `shibot`, `gumnut`, `remy`.

## Outcome

All four deployed agents were upgraded to `OpenClaw 2026.5.5` and passed target-specific functional checks:

| Agent   | Container                            | Result | Evidence                                                                             |
| ------- | ------------------------------------ | ------ | ------------------------------------------------------------------------------------ |
| clawops | `clawops-gateway`                    | PASS   | local smoke suite passed, config valid, plugins doctor clean                         |
| shibot  | `openclaw-docker-openclaw-gateway-1` | PASS   | agent exact-response QA, browser snapshot, Himalaya present                          |
| gumnut  | `gumnut-bot-gateway`                 | PASS   | agent exact-response QA, browser snapshot, Himalaya present, Duckbill tool QA passed |
| remy    | `remy-bot-gateway`                   | PASS   | agent exact-response QA, browser snapshot, Himalaya present                          |

## Important Process Finding

The multi-target smoke path using `CLAWOPS_TARGET_<NAME>_URL=ws://10.108.0.2:<port>` produced false-negative timeouts from inside containers even after rollback to `2026.5.3-1`.

Observed false-negative failures:

- `session-turn-1` / `session-turn-2` timed out in target mode.
- Browser persistence checks failed in target mode.
- Integration `gateway-rpc` timed out when probing `ws://10.108.0.2:18795` from inside the container.

The local in-container smoke path on the same gateway passed and should be the current canary gate until target-mode transport is fixed.

## Current Recommended Upgrade Gate

1. Check latest version:

```bash
npm view openclaw version dist-tags --json
```

2. Canary only on clawops by image tag:

```bash
scripts/ops/clawops/docker-image-rollout.sh \
  --remote sreeopsadmin@10.108.0.2 \
  --version 2026.5.5 \
  --canary clawops \
  --targets clawops,shibot,gumnut,remy \
  --skip-rollout
```

3. Accept canary only if all pass:

- container health becomes healthy
- `openclaw --version` matches target
- `openclaw config validate` passes
- `openclaw plugins doctor` has no actionable issue
- clawops local smoke suite passes
- integration checks pass: gateway RPC, health, MCP list, Himalaya, Duckbill smoke

4. Roll target-by-target:

```bash
scripts/ops/clawops/docker-image-rollout.sh \
  --remote sreeopsadmin@10.108.0.2 \
  --version 2026.5.5 \
  --rollback-version 2026.5.3-1 \
  --targets clawops,shibot,gumnut,remy
```

5. Stop rollout immediately if a target fails its exact-response agent check, browser snapshot, plugin doctor, or custom capability check.

## Rollback Procedure

For any target:

1. Restore the previous image tag in that deployment `.env`.
2. Recreate only that deployment.
3. Wait for Docker health.
4. Rerun the same target QA.

Example for clawops:

```bash
ssh sreeopsadmin@10.108.0.2 'cd /opt/clawops && \
  sudo sed -i "s#^OPENCLAW_IMAGE=.*#OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:2026.5.3-1#" .env && \
  sudo docker compose up -d --force-recreate clawops-gateway'
```

## Backups Created

Each target rollout creates timestamped backups under the deployment directory:

- `/opt/clawops/backups/upgrade-*`
- `/opt/openclaw-docker/backups/upgrade-*`
- `/opt/gumnut-bot/backups/upgrade-*`
- `/opt/remy-bot/backups/upgrade-*`

## Follow-ups

- Fix multi-target smoke transport so container-to-container checks do not depend on host Tailscale IP hairpinning.
- Convert target-mode browser checks to execute inside the target container, or add per-target loopback URL semantics for container-local probes.
- Update release watcher/canary automation to use Docker image tags for compose-managed deployments instead of `openclaw update` inside a running container.
- Set explicit `plugins.allow` on clawops/remy/shibot. Gumnut already has a narrow allowlist and should be the model.
- Clean Shibot stale plugin entries or intentionally install the external plugins now suggested by `2026.5.5` warnings.
