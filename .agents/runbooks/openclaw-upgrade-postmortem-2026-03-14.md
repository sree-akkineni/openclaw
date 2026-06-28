# OpenClaw Droplet Upgrade Postmortem (March 14, 2026)

## Scope
Postmortem for the OpenClaw agent upgrade/debug cycle on the production droplet covering:
- `clawops-gateway`
- `remy-bot-gateway`
- `gumnut-bot-gateway`
- `openclaw-docker-openclaw-gateway-1`

This note captures what actually happened, what we got wrong, what the optimal process should have been, and what changes would have prevented the confusion and rework.

## Executive summary
The system was not stuck on a single bug. It was a chain of separate failures:

1. `clawops` and `remy` originally failed on the old OpenAI GPT-5.4 WebSocket transport path.
2. That was fixed by moving them to the HTTP/Responses provider path.
3. We then believed the runtime had been upgraded, but the live containers were still running OpenClaw `2026.2.21`.
4. A real `2026.3.13` image was built, but all four gateways were first rolled onto the browser-capable image in parallel.
5. On this droplet, that startup pattern overloaded CPU/memory and left all four gateways unhealthy.
6. The correct fix was to split images by role and roll them out sequentially:
   - browser image only for `main`
   - core image for `clawops`, `remy`, `gumnut`
7. `clawops` also needed `doctor --fix` after the upgrade so its legacy `safeBins` policy would keep working under the new `safeBinProfiles` expectations.

## Final good state
- `clawops-gateway`: `openclaw:2026.3.13-core-custom`
- `remy-bot-gateway`: `openclaw:2026.3.13-core-custom`
- `gumnut-bot-gateway`: `openclaw:2026.3.13-core-custom`
- `openclaw-docker-openclaw-gateway-1`: `openclaw:2026.3.13-custom`

All four ended healthy. `x_search` worked on all four. `main` browser actions worked. Direct reply smokes worked for all four, with `gumnut` requiring a natural-language prompt rather than an operator-style token prompt.

## Verification caveat
- The in-container `openclaw agent` CLI smokes fell back from gateway WebSocket mode to embedded mode.
- That did not block the user-facing gateways, because health checks, `/tools/invoke`, `x_search`, and browser actions were verified directly against the live HTTP gateways.
- But it does mean one verification path was weaker than ideal.
- Follow-up item: separately debug why local `openclaw agent` does not stay attached to the live gateway WS path on these containers.

## What actually happened

### Phase 1: Original GPT-5.4 failures
- `clawops` and `remy` were failing on the runtime's older OpenAI WebSocket transport path.
- The live runtime on the droplet did not match the newer docs that described the newer transport controls.
- We fixed that by moving the affected agents to the `openai-http` provider path with fallbacks.

### Phase 2: Wrong belief that the runtime was upgraded
- We had a custom image tag in use: `openclaw:2026.3.8-custom`.
- The tag name suggested a newer runtime than what was actually inside the container.
- The containers were still running OpenClaw `2026.2.21`.
- `clawops` correctly reported that the codebase/runtime had not actually been upgraded.

### Phase 3: Built image existed, but deployment did not
- We built a real `openclaw:2026.3.13-custom` image.
- That build was successful.
- But the running stacks were still pinned to the old image references.
- Result: the host had the new image locally, while production kept serving the old runtime.

### Phase 4: First real rollout was done incorrectly
- We switched all four stacks to the browser-enabled `2026.3.13` image at once.
- That image includes browser support and is materially heavier during startup.
- The droplet has only 3.8 GiB RAM total, and each container had a `1.2 GiB` cap.
- Starting four heavy runtimes in parallel caused startup thrash.
- Symptom pattern:
  - high CPU on all four
  - memory pushed close to container limits
  - `/healthz` reset connections
  - Docker marked all four unhealthy

### Phase 5: Corrected rollout
- We built a second image without browser dependencies:
  - `openclaw:2026.3.13-core-custom`
- We mapped images to actual needs:
  - `main` stays on browser image
  - `clawops`, `remy`, `gumnut` use core image
- We restarted one gateway at a time and waited for steady-state memory and `200 /healthz` before starting the next.
- That worked cleanly.

### Phase 6: Remaining clawops upgrade friction
- Under the new runtime, `clawops` logged that legacy `tools.exec.safeBins` entries were ignored because matching `safeBinProfiles.<bin>` entries were missing.
- That was not a fatal outage, but it directly affected the "clawops should manage upgrades/ops tasks" goal.
- Running `doctor --fix` on `clawops` scaffolded the missing profiles and removed the warning.

## Errors we made

### 1. We trusted image tags instead of runtime facts
Mistake:
- We treated `openclaw:2026.3.8-custom` as proof of runtime version.

Why that was wrong:
- Image tag names are metadata.
- The only trustworthy checks are:
  - `docker exec <container> node -p "require('/app/package.json').version"`
  - actual tool availability
  - actual health behavior

Optimal behavior:
- Every rollout must verify the package version inside the running container immediately after recreate.

### 2. We verified builds, not deployment
Mistake:
- We confirmed the `2026.3.13` image had been built, but did not immediately prove the services were using it.

Why that was wrong:
- Build success only proves local image availability.
- It says nothing about compose references, env pins, or what is currently running.

Optimal behavior:
- Deployment is not complete until all of these match:
  - image exists
  - compose/env references point to it
  - container image matches
  - runtime version inside container matches

### 3. We used one heavy image for every agent
Mistake:
- We rolled browser-enabled runtime everywhere.

Why that was wrong:
- Only `main` needed browser capability.
- The heavier image added avoidable startup pressure to `clawops`, `remy`, and `gumnut`.

Optimal behavior:
- Keep separate deploy targets:
  - core image for non-browser agents
  - browser image only where browser is required

### 4. We restarted too much in parallel on a small host
Mistake:
- We recreated multiple gateways together during a major runtime jump.

Why that was wrong:
- On a 3.8 GiB host, startup spikes matter.
- Parallel startup made diagnosis noisy and made a recoverable rollout look broken.

Optimal behavior:
- Sequential rollout only:
  1. recreate one gateway
  2. wait for healthy
  3. verify memory settles
  4. run smoke
  5. continue to next gateway

### 5. We did not run post-upgrade `doctor --fix` early enough
Mistake:
- We let the new runtime boot against legacy config and policy state without immediately normalizing it.

Why that was wrong:
- The newer runtime had compatibility expectations around:
  - `safeBinProfiles`
  - session key normalization
  - various migrated config shapes

Optimal behavior:
- After major version jumps, run `doctor --fix --non-interactive --yes` against the upgraded config before calling the rollout complete.

### 6. We mixed two approval strategies mentally
Mistake:
- We treated the older "reply with `/approve allow-once` and infer latest id" patch and the new runtime's Telegram-native exec approvals as if they were the same thing.

Why that was wrong:
- They solve overlapping UX problems in different ways.
- On `2026.3.13`, the correct live path is Telegram native exec approvals with buttons/config.

Optimal behavior:
- Prefer native approval clients first.
- Only carry custom command fallbacks when native behavior still leaves a real operator gap.

### 7. We did not distinguish "agent healthy" from "agent operationally convenient"
Mistake:
- We initially focused on health/reply success and only later returned to the exec-policy friction that matters for upgrades.

Why that was wrong:
- The user's actual requirement was stronger:
  - agent must not just reply
  - agent must be usable for ops work from Telegram

Optimal behavior:
- Verification must include user-task-specific flows, not only generic health checks.

### 8. Our first gumnut smoke was badly chosen
Mistake:
- We used an operator-style exact-token prompt against a persona that interprets terse command-like phrasing differently.

Why that was wrong:
- It created false ambiguity around runtime health.

Optimal behavior:
- Use persona-compatible smoke prompts:
  - one exact-token prompt for strict ops agents
  - one plain factual prompt for conversational/persona-heavy agents

## Process gaps that allowed this

### Missing deployment checklist
We did not enforce a single checklist requiring:
- build image
- update references
- recreate service
- verify live version
- verify health
- run smoke

### Missing image-role mapping
There was no explicit documented rule that:
- `main` uses browser image
- everyone else uses core image

### Missing capacity-aware rollout policy
There was no documented rule to avoid parallel recreate on this droplet.

### Missing post-upgrade config normalization step
We did not treat `doctor --fix` as mandatory after a major runtime jump.

### Missing explicit-default discipline
We allowed production surfaces to inherit runtime defaults for capabilities that define the agent's role.

Why that mattered:
- `browser.enabled` defaulted on when it should have been explicitly off for `clawops`, `remy`, and `gumnut`
- Telegram ops behavior was treated as implied by approvals, even though elevated host actions still require explicit `tools.elevated` gating

Optimal behavior:
- treat browser and elevated-op capability as role boundaries
- encode them explicitly in live config
- make the verifier fail when they are unset

### Missing remote write verification
We were too willing to trust that a remote edit command had landed without immediately reading the live file back.

Why that mattered:
- a failed or misquoted remote edit can look like success if the next check only reads health or a partial symptom
- that delays root-cause isolation and creates fake progress

Optimal behavior:
- after every live config write:
  1. read the exact file back
  2. verify the intended keys and values
  3. restart only the affected service
  4. rerun the verifier

### Missing failure classification discipline
We used “timeouts” as a catch-all label for unrelated problems.

Why that mattered:
- host overload, provider `429`s, loopback handshake noise, and config drift need different fixes
- collapsing them into one incident produced the wrong interventions

Optimal behavior:
- classify each symptom before acting:
  - host capacity
  - provider rate limit / quota
  - config drift / missing capability
  - local control-plane noise

## Optimal process knowing what we know now

### Preflight
1. Verify current live versions from inside running containers.
2. Record current image references from compose/env.
3. Record host capacity:
   - total RAM
   - per-container memory limits
4. Decide image split before building:
   - browser vs core

### Build
1. Build `openclaw:<version>-core-custom`
2. Build `openclaw:<version>-custom` only if browser is needed
3. Verify inside each image:
   - package version
   - expected custom tools (`x_search`)
   - browser binary presence only in browser image

### Rollout
1. Update image references explicitly.
2. Run `doctor --fix` on the target config if the version jump is significant.
3. Recreate exactly one gateway.
4. Wait until:
   - container is healthy
   - `/healthz` returns `200`
   - memory settles near steady state
5. Run smoke for that gateway.
6. Move to the next gateway.

### Verification matrix
For each gateway:
- runtime version inside container
- `200 /healthz`
- direct reply smoke
- `web_search`
- `x_search`
- browser status/open/tabs where applicable
- operator-specific approval UX where applicable
- explicit config read-back for browser/elevated role boundaries where applicable

### Completion criteria
Do not send "upgrade complete" messages until:
- all targeted gateways are on the expected runtime
- all required tools work
- approval UX is usable from the actual operator surface

## Concrete prevention changes we should make

### Operational
- Add a deployment checklist to the runbook.
- Add a hard rule: no parallel recreates for major upgrades on this droplet.
- Keep two maintained image targets:
  - `core`
  - `browser`

### Automation
- Add a post-deploy verification script that prints:
  - running container image
  - package version inside container
  - healthz result
  - memory usage
  - tool smoke results
- Make it fail if explicit role booleans are unset where production policy requires them.
- Make it fail if an ops surface is missing explicit Telegram elevated gating.
- Fail the deployment if any service is still on the previous version.

### Config hygiene
- Make `doctor --fix` part of major-version rollout.
- Keep Telegram `execApprovals` explicitly configured in the live agent configs rather than relying on ad hoc memory of prior changes.

### UX / agent-operability
- For ops agents, validate not only reply and tools but also:
  - approval routing
  - approval authorization
  - whether the agent's exec policy still recognizes the bins it needs for maintenance work

### Debugging discipline
- Do not use boolean-fallback inspection patterns that hide explicit `false` values.
- After any remote edit command, verify the file contents before moving on.
- Prefer literal heredocs for complex remote shell edits so quoting does not silently change the payload.

## Short version: our errors vs the optimal process

Our errors:
- trusted image tags
- verified builds instead of deployment
- rolled heavy image everywhere
- restarted too much in parallel
- delayed config normalization
- tested generic health before operator usability

Optimal process:
- verify runtime inside containers
- split images by role
- roll out one gateway at a time
- run `doctor --fix`
- verify health, memory, tools, browser, approval UX, and explicit config read-back
- only then announce completion

## Recommended next follow-ups
- Add a `scripts/gateway-verify-upgrade.sh` style verification script.
- Add a runbook section for `core` vs `browser` image assignment.
- Add a runbook section for sequential rollout on low-memory hosts.
- Decide whether the native Telegram approval buttons are sufficient, or whether the no-id `/approve allow-once` fallback still needs to be ported to `2026.3.13`.
