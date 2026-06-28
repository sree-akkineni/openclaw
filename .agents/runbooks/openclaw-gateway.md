# OpenClaw Production Droplet Runbook

## Purpose
This directory is the persistent operational memory for the production droplet.

Use the files in this order:
- `AGENTS.md`: short guardrails and mandatory-reading pointers only.
- `.agents/runbooks/openclaw-gateway.md`: stable operating procedure.
- `.agents/runbooks/openclaw-live-state.md`: current live inventory and known-good state. Update this after live changes.
- `.agents/runbooks/openclaw-live-state.json`: machine-readable inventory for automation and verification scripts.
- `.agents/runbooks/openclaw-upgrade-postmortem-YYYY-MM-DD.md`: dated incident history and process lessons.

Do not try to turn `AGENTS.md` into a full live-state dump. Keep durable rules in `AGENTS.md`, procedures here, and mutable production facts in `openclaw-live-state.md`.

## Mandatory Reading Before Touching Prod
Read these before making live changes:
1. `.agents/runbooks/openclaw-live-state.md`
2. `.agents/runbooks/openclaw-gateway.md`
3. The newest `.agents/runbooks/openclaw-upgrade-postmortem-*.md` if the task involves upgrades, outages, rollout drift, or approval UX regression

## Access
- Preferred SSH path: `ssh sreeopsadmin@10.108.0.2`
- Public fallback only: `ssh sreeopsadmin@157.245.220.134`
- Treat the private/Tailscale path as canonical unless a newer documented access path replaces it.
- If the operator uses a local SSH alias or jump host, prefer that documented alias and update `openclaw-live-state.md`.

## Where Live Truth Comes From
- The droplet is the source of truth for:
  - running container images
  - runtime versions
  - current config files
  - health behavior
  - tool availability
- A local repo checkout or built image is not proof that production is upgraded.
- For agent transcripts, read `~/.openclaw/agents/<agentId>/sessions/*.jsonl` on the host.
- After a recreate, verify the live runtime from inside the running container:

```sh
docker exec <container> node -p "require('/app/package.json').version"
```

Use `sudo docker ...` if the shell user is not in the Docker group.

## Hard Rules
- Keep `main` on the browser image unless you are explicitly changing its role.
- Keep `clawops`, `remy`, and `gumnut` on the core image unless they truly need browser support.
- Do not recreate all four gateways in parallel during major upgrades on this droplet.
- After meaningful runtime jumps, run `openclaw doctor --fix --non-interactive --yes` against the target config before calling the rollout complete.
- Do not announce completion until runtime version, health, required tools, and operator UX are all verified.
- After any remote config change, read the live config file back immediately and rerun the verifier before treating the edit as real.
- For X bearer tokens copied from the X developer console, store the token exactly as pasted. Do not URL-decode or normalize it.
- Prefer native Telegram `execApprovals` on current runtime instead of workflows that depend on manually typing approval IDs.
- Do not enable generic `approvals.exec` forwarding on the same Telegram surface that already uses native `channels.telegram.execApprovals` for operator approvals. Keep one approval UI path per bot unless you have explicitly verified a non-overlapping route.
- Do not rely on implicit runtime defaults for browser or elevated ops:
  - set `browser.enabled=false` explicitly on non-browser surfaces
  - set `browser.enabled=true` explicitly on the browser surface
  - if a surface must run elevated host actions from Telegram, set `tools.elevated.enabled=true` and `tools.elevated.allowFrom.telegram=[...]` explicitly
- Do not collapse `false` and unset when inspecting live booleans. For gateway diagnostics, explicit `false` is a real state, not “missing.”

## Major Upgrade Workflow
1. Read `openclaw-live-state.md` and the latest postmortem.
2. Record the current live runtime version, image, and health for each gateway.
3. Decide the image split before rollout:
   - core image for non-browser agents
   - browser image only where browser is actually required
4. Build or pull the target images.
5. Update compose or environment references explicitly.
6. Run `doctor --fix` if the version jump is material or config warnings appear.
7. Recreate exactly one gateway.
8. Wait for the container to become healthy and for memory to settle.
9. Verify the runtime version inside that running container.
10. Run the gateway smoke checks:
   - direct reply
   - `web_search`
   - `x_search`
   - browser commands where applicable
   - actual Telegram approval UX where applicable
   - `scripts/gateway-verify-upgrade.sh`
11. Move to the next gateway only after the previous one is healthy and smoke-checked.
12. Update `.agents/runbooks/openclaw-live-state.md` in the same change set.
13. If a new failure mode or process lesson was discovered, add or update a dated postmortem.

## Verification Checklist
Run the checks against the live gateway, not only against a local CLI wrapper:

```sh
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
docker logs --since=30m <container> | tail -n 200
docker exec <container> node -p "require('/app/package.json').version"
docker port <container>
```

Verify all of the following for the gateways you changed:
- healthy container state
- expected runtime version inside the container
- `/healthz` success
- required tool smoke via live `/tools/invoke`
- direct reply smoke
- real operator approval flow in Telegram for agents that need exec approvals
- for browser-enabled surfaces, confirm a supported browser binary exists inside the running container
- read-back of the live config file showing the expected explicit booleans and elevated gates

If `openclaw agent` inside the container falls back to embedded mode, do not treat that as proof that the live gateway WS path is healthy. Use `/healthz`, `/tools/invoke`, and real channel behavior as the source of truth until that fallback is separately debugged.

## Failure Classification
Before calling an incident “timeouts” or “the droplet is overloaded,” classify it:
- host capacity issue:
  - high load
  - low available RAM
  - concurrent recreate/startup thrash
- provider-side rate limit or quota:
  - `429`
  - `API rate limit reached`
  - cooldown / auth-profile exhaustion
- config or capability drift:
  - runtime version mismatch
  - implicit defaults enabled the wrong surface
  - expected tool not exposed
  - elevated or approval path missing
- loopback/control-plane noise:
  - local `127.0.0.1` handshake timeout
  - embedded CLI fallback that does not reflect user-facing gateway health

Do not merge these into one diagnosis. Capture the specific class in the live-state note or postmortem.

## Update Policy
After any live change, update `.agents/runbooks/openclaw-live-state.md` if any of the following changed:
- access path
- host directories
- config file paths
- container names
- image mapping
- runtime version
- provider or model mapping
- tool policy
- approval configuration
- verification caveats

Append a dated change note there when you make live changes. Keep dated lessons and failure analysis in a separate postmortem file rather than expanding the stable runbook with incident narrative.

## Verification Script
Use `scripts/gateway-verify-upgrade.sh` after live rollouts. It reads `.agents/runbooks/openclaw-live-state.json`, SSHes to the documented host, and verifies:
- running container image
- runtime version inside the container
- healthy Docker state
- `/healthz`
- memory usage snapshot
- required HTTP tool smokes
- browser binary presence for browser-enabled surfaces
- Telegram `execApprovals` config
- generic exec-approval forwarding state (`approvals.exec.enabled`) when encoded in the live-state manifest
- explicit browser role config (`browser.enabled`) and expected executable path when applicable
- explicit Telegram elevated config for surfaces that must manage host ops
- whether the optional no-id `/approve` text fallback is present in the running bundle
  - this must validate the real no-id parser (`Usage: /approve [id] ...`) and the missing-latest error path, not only the generic approval prompt text

If you change the live stack inventory, expected images, or required tool smokes, update `.agents/runbooks/openclaw-live-state.json` in the same change set.
