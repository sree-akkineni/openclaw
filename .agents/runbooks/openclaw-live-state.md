# OpenClaw Production Live State

## Purpose
This file is the current known-good state of the production droplet. Update it after live changes. Use `.agents/runbooks/openclaw-gateway.md` for procedure and `.agents/runbooks/openclaw-upgrade-postmortem-*.md` for dated incident history.

The machine-readable twin for scripts is `.agents/runbooks/openclaw-live-state.json`. Keep both in sync.

## Last Verified
- Date: June 28, 2026
- Verified outcomes:
  - all four gateways are currently healthy after the June 28 reboot
  - all four surfaces are currently on `ghcr.io/openclaw/openclaw:2026.6.9`
  - all four runtime versions are currently `2026.6.9`
  - `memory.backend="qmd"` is still enabled on all four live configs
  - explicit `browser.enabled=true` is still present on all four live configs
  - `clawops` still has explicit Telegram elevated config
  - all four gateways currently pass `openclaw models status --check`
  - `main` now has Telegram `execApprovals` restored with target `both` and approvers `1944676289`, `5944352446`
  - private SSH over Twingate was restored for `sreeopsadmin@10.108.0.2`
  - `clawops` OOM evidence from the previous boot was preserved in the journal and mapped to container `clawops-gateway`
  - a dedicated droplet health monitor script + timer now exist in the repo for host deployment
- Known caveat:
  - the in-container `openclaw agent` CLI may fall back to embedded mode instead of staying attached to the live gateway WebSocket path
  - until that is debugged, prefer live `/healthz`, `/tools/invoke`, and real channel behavior as proof
  - there is still no Obsidian vault mounted on the droplet; QMD currently indexes only default workspace memory files (`MEMORY.md` and `memory/*.md`)
  - `clawops` logged repeated `active-memory` `openai-http` auth failures before the reboot; those failures are not present after the current boot, but the incident should be treated as auth-path drift until reproduced or ruled out
  - `clawops` is the surface that hit repeated cgroup OOM kills in the prior boot; host-wide free memory after reboot is healthy, so classify future incidents at the container level first
  - `perplexity` and `slack` plugin config warnings are currently present on some surfaces; config and installed plugin set are not fully aligned
  - the currently deployed `2026.6.9` images do not include the no-id Telegram `/approve allow-once|allow-always|deny` text fallback; current live path is native Telegram buttons plus explicit-id `/approve <id> ...`

## Access And Host
- Preferred SSH path: `ssh sreeopsadmin@10.108.0.2`
- Public fallback: `ssh sreeopsadmin@157.245.220.134`
- Host currently reports about `7.8 GiB` RAM total and `2 GiB` swap
- Major runtime upgrades must be rolled out sequentially
- The browser-enabled image is materially heavier at startup than the core image

## Live Stack Inventory
| Surface | Host directory | Config path | Container | Current image | Notes |
| --- | --- | --- | --- | --- | --- |
| `clawops` | `/opt/clawops` | `/opt/clawops/config/openclaw.json` | `clawops-gateway` | `ghcr.io/openclaw/openclaw:2026.6.9` | Primary ops surface; `browser.enabled=true`; Telegram approvals target `both`; `tools.elevated.enabled=true`; prior boot had repeated cgroup OOM kills in this container and repeated `active-memory` `openai-http` auth failures before reboot |
| `remy` | `/opt/remy-bot` | `/opt/remy-bot/config/openclaw.json` | `remy-bot-gateway` | `ghcr.io/openclaw/openclaw:2026.6.9` | Research surface; `browser.enabled=true`; Telegram approvals target `both`; `memory.backend="qmd"`; currently healthy |
| `gumnut` | `/opt/gumnut-bot` | `/opt/gumnut-bot/config/openclaw.json` | `gumnut-bot-gateway` | `ghcr.io/openclaw/openclaw:2026.6.9` | Claude Opus primary via Claude CLI; `browser.enabled=true`; Telegram approvals target `channel`; Duckbill MCP still configured; currently healthy |
| `main` / `shibot` / `shibotinu` | `/opt/openclaw-docker` | `/opt/openclaw-docker/config/openclaw.json` | `openclaw-docker-openclaw-gateway-1` | `ghcr.io/openclaw/openclaw:2026.6.9` | Heavy research surface; browser on; Telegram approvals target `both`; currently healthy |

## Runtime And Image Policy
- The live host is currently running `ghcr.io/openclaw/openclaw:2026.6.9` on all four surfaces.
- `browser.enabled` must be explicit on every surface. Do not leave it unset on non-browser agents; the runtime default is enabled.
- The earlier `core`/`browser` split is not what the host is currently running. Treat the manifest as authoritative for verification and read the live config before assuming role boundaries.
- `clawops` is the only default Telegram ops surface. It needs explicit `tools.elevated.enabled=true` and explicit `tools.elevated.allowFrom.telegram`.
- The March 14, 2026 failure came from rolling the browser image to all four gateways in parallel on a small host. Do not repeat that rollout shape.

## Shared Environment And Credentials
- Shared environment file used by the stacks: `/opt/shared.env`
- Important shared keys:
  - `PERPLEXITY_API_KEY`
  - `X_BEARER_TOKEN`
- `NOTION_API_KEY` is intentionally scoped to `main` / `shibotinu` via `/opt/openclaw-docker/.env` plus an explicit `environment` binding in `/opt/openclaw-docker/docker-compose.yml`; it is not currently present in `/opt/shared.env`
- `X_BEARER_TOKEN` must be stored exactly as copied from the X developer console. Do not URL-decode or normalize it.
- After changing `/opt/shared.env`, recreate only the affected gateways and rerun live tool smokes.
- After changing stack-local `.env` plus compose `environment` bindings, recreate only that stack and verify the env is present inside the running container before claiming the secret is usable.

## Shared Skills
- Managed/shared skills live under each stack config volume at `<config>/skills`.
- `agent-browser` is installed for all four live surfaces.
- Current sources:
  - `clawops`: `/opt/clawops/config/skills/agent-browser`
  - `remy`: `/opt/remy-bot/config/skills/agent-browser`
  - `gumnut`: `/opt/gumnut-bot/config/skills/agent-browser`
  - `main`: both `/opt/openclaw-docker/config/skills/agent-browser` and `/opt/openclaw-docker/workspace/skills/agent-browser` exist; the workspace copy wins by precedence.
- To share a skill across all agents on this host, copy the skill folder into each stack’s `<config>/skills` directory or place it in the relevant workspace if you intentionally want a per-surface override.

## QMD Memory Runtime
- QMD runtime is staged per stack under `<config>/qmd-runtime/` and executed from the mounted config volume:
  - `clawops`: `/root/.openclaw/qmd-runtime/node_modules/.bin/qmd`
  - `remy`: `/root/.openclaw/qmd-runtime/node_modules/.bin/qmd`
  - `gumnut`: `/root/.openclaw/qmd-runtime/node_modules/.bin/qmd`
  - `main`: `/home/node/.openclaw/qmd-runtime/node_modules/.bin/qmd`
- Installed version verified in the live containers: `qmd 2.0.1`
- Current scope is the default workspace memory roots only. No extra `memory.qmd.paths` are configured yet because the droplet does not currently have an Obsidian vault path mounted.

## Approval UX Expectations
- Current live path relies on native Telegram `execApprovals` first.
- Telegram DM exec-approval buttons are present on the configured bots. The remaining verification step is a real operator click canary on `clawops`.
- Generic `approvals.exec` forwarding should stay off on the Telegram-native surfaces unless you are intentionally routing approvals to a different destination and have verified that the UI will not duplicate.
- The explicit-id form `/approve <id> allow-once|allow-always|deny` is the current text fallback path.
- Expected approval targets:
  - `clawops`: `both`
  - `remy`: `both`
  - `gumnut`: `channel`
  - `main`: `both`
- `clawops` is expected to be operable for upgrades and maintenance from Telegram, so verify a real approval prompt or button flow after runtime changes.

## Tool And Ops Expectations
- `clawops` must remain usable for ops work:
  - reply
  - `exec`
  - `web_search`
  - `web_fetch`
  - `x_search`
- `remy` should stay narrow by default:
  - reply
  - `web_search`
  - `web_fetch`
  - `x_search`
  - avoid `browser` and broad `exec` access unless intentionally changing role
- `gumnut` should support reply plus web/X research without browser by default
- `main` is the broad research surface and is the default place for browser-backed tasks
- Browser-backed tasks are not verified by API surface alone; the browser-enabled surface must also have a real Chromium/Chrome-class binary installed inside the running container
- Native Telegram `execApprovals` are necessary but not sufficient for host ops. A surface that must run elevated host actions from Telegram also needs explicit `tools.elevated` gating for Telegram.

## Health Monitoring
- Repo monitor script: `scripts/droplet-health-monitor.sh`
- Repo timer units:
  - `scripts/systemd/openclaw-droplet-health-monitor.service`
  - `scripts/systemd/openclaw-droplet-health-monitor.timer`
- Intended host install path: `/usr/local/bin/openclaw-droplet-health-monitor.sh`
- Default log path on host: `/var/log/openclaw-health/`
- The monitor is meant to catch:
  - recent kernel OOM events
  - unhealthy or missing gateway containers
  - recent auth failures in gateway logs
  - low available memory / swap pressure
  - high per-container memory utilization

## Useful Host Paths
- Session logs: `~/.openclaw/agents/<agentId>/sessions/*.jsonl`
- Shared env: `/opt/shared.env`
- Main config: `/opt/openclaw-docker/config/openclaw.json`
- Clawops config: `/opt/clawops/config/openclaw.json`
- Remy config: `/opt/remy-bot/config/openclaw.json`
- Gumnut config: `/opt/gumnut-bot/config/openclaw.json`

## Change Log
- 2026-03-18:
  - gumnut now runs with `agents.defaults.model.primary="claude-cli/opus-4.6"` and provider fallback to Anthropic/OpenAI
  - added `agents.defaults.cliBackends["claude-cli"]` in `/opt/gumnut-bot/config/openclaw.json` to execute Claude as the `node` user with strict MCP config
  - added Duckbill MCP config files on host:
    - `/opt/gumnut-bot/config/mcp/duckbill.json`
    - `/opt/gumnut-bot/config/claude-home/duckbill.json` (active path mounted to `/home/node/.claude/duckbill.json`)
  - updated `/opt/gumnut-bot/docker-compose.yml` to mount node-scoped OpenClaw/Claude paths and bootstrap `@anthropic-ai/claude-code` if missing
  - confirmed container health and Telegram provider startup with `agent model: claude-cli/opus-4.6`
  - restored compose healthcheck to `${GATEWAY_PORT:-18796}` after validation drift
  - verified sensitive values were preserved (Telegram token/chat id, gateway token, browser token unchanged vs pre-change backup)
  - current blocker: Claude Code auth for `node` is still not logged in (`runuser -u node -- claude auth status` shows `loggedIn: false`)
- 2026-03-16:
  - installed QMD `2.0.1` into each live stack’s managed config volume under `qmd-runtime/`
  - enabled `memory.backend="qmd"` with explicit `memory.qmd.command` on `clawops`, `remy`, `gumnut`, and `main`
  - restarted each gateway sequentially after the config change and verified all four returned to healthy
  - verified QMD-backed memory retrieval on `main` (`Ratatouille`) and `gumnut` (`Browner Sound`) via live `/tools/invoke`
  - verified QMD backend status on `remy` (`Danny’s 40th`) and `clawops` (empty workspace index) via `openclaw memory`
  - documented that production still lacks a mounted Obsidian vault path, so the current QMD rollout covers workspace memory only
- 2026-03-15:
  - installed `agent-browser` for all four live surfaces by copying the skill folder into each stack’s managed `config/skills` directory
  - verified `agent-browser` is eligible on `clawops`, `remy`, and `gumnut` from `openclaw-managed`; `main` still resolves its workspace copy first via `openclaw-workspace`
  - corrected the live-state manifest to match the actual all-`custom` runtime and explicit `browser.enabled=true` config on all four surfaces
  - bound `NOTION_API_KEY` into `/opt/openclaw-docker` gateway container env so `main` / `shibotinu` exec tasks can use the Notion API directly
  - verified the live `main` Notion token path with an in-container `GET https://api.notion.com/v1/users/me` probe returning HTTP `200`
  - removed generic `approvals.exec` forwarding from `clawops` so Telegram exec approvals come from a single native path
  - deployed host-built hotfix images `openclaw:2026.3.13-core-custom-approve-latest1` and `openclaw:2026.3.13-custom-approve-latest1`
  - restored the no-id Telegram `/approve allow-once|allow-always|deny` fallback on all four surfaces
  - added verifier coverage for generic exec-approval forwarding drift on Telegram-native surfaces
  - tightened verifier coverage so the approval fallback check requires the real no-id parser, not just any approval prompt text
  - documented the duplicate approval UI failure mode in `openclaw-upgrade-postmortem-2026-03-15.md`
- 2026-03-14:
  - upgraded live runtimes to `2026.3.13`
  - split images by role: browser image only on `main`, core image on `clawops`, `remy`, and `gumnut`
  - fixed X token handling by keeping the bearer token literal as copied from the X developer console
  - verified `x_search` on all four gateways
  - verified browser commands on `main`
  - enabled Telegram native `execApprovals` on the relevant bots
  - ran `doctor --fix` on `clawops` to normalize legacy exec policy config
  - set `browser.enabled=false` explicitly on `clawops`, `remy`, and `gumnut`
  - verified `main` is the only browser-enabled surface and that its configured Chromium path exists in the running container
  - set explicit `tools.elevated.enabled=true` and `tools.elevated.allowFrom.telegram` on `clawops`
  - verified `scripts/gateway-verify-upgrade.sh` passes 4/4 surfaces against the live host
