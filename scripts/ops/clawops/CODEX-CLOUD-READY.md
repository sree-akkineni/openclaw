# Codex Cloud Readiness Notes

## Goal

Make this repo practical to work on from Codex Cloud while on the go. Codex Cloud should support code changes, docs, planning, tests, and PR-ready branches. Production deploys stay local through ACP or a trusted Mac/Mac mini with Twingate access to the droplet.

## Operating Model

Two separate lanes:

| Lane           | Use For                                                         | Runs From                   | Network/Secrets                                 |
| -------------- | --------------------------------------------------------------- | --------------------------- | ----------------------------------------------- |
| Codex Cloud    | Repo work, code edits, docs, tests, roadmap iteration, PR prep  | ChatGPT/Codex Cloud VM      | GitHub repo access plus dependency install only |
| Production ops | Droplet deploys, OpenClaw agent restarts, live smoke, rollbacks | ACP to this Mac or Mac mini | Twingate SSH alias and local operator secrets   |

Do not make the Codex Cloud VM responsible for DigitalOcean droplet deploys by default. That adds Twingate/client/key complexity and increases secret exposure without much benefit.

## Current Good State

- Repo has file-backed ops artifacts under `scripts/ops/clawops/`.
- Upgrade evidence and process notes are committed to repo docs rather than only chat.
- `docker-image-rollout.sh` provides a repeatable entrypoint for image-based droplet upgrades when run from an approved local operator machine.
- Stream C memory work remains local and inspectable under `scripts/ops/clawops/stream-c/`.
- Codex Cloud setup has a repo-local script: `scripts/ops/clawops/codex-cloud-setup.sh`.

## Codex Cloud Environment Form

Use these settings for the environment shown in the Codex Cloud UI.

Description:

```text
OpenClaw repo coding and QA environment for mobile/on-the-go work. Production deploys are intentionally handled from ACP/local Macs over Twingate, not from this VM.
```

Sharing:

```text
Only you
```

Container image:

```text
universal
```

Container caching:

```text
On
```

Setup script mode:

```text
Manual
```

Setup script:

```bash
bash scripts/ops/clawops/codex-cloud-setup.sh
```

Do not put `pnpm check` or full test suites in the setup script. Setup runs when containers are created and should stay cacheable. Run validation inside the task after Codex has made changes.

Maintenance script:

```bash
corepack enable
pnpm install --frozen-lockfile --prefer-offline
```

Environment variables:

```text
None required for default repo work.
```

Secrets:

```text
None by default.
```

Only add secrets for a specific cloud task after deciding they are safe for Codex Cloud. Do not add droplet SSH keys, live OpenClaw gateway tokens, ChatGPT personal credentials, phone numbers, or production `.env` values.

## Validation Commands In Cloud Tasks

Use scoped validation first, then broaden if the change touches shared/runtime surfaces.

Docs and ops script edits:

```bash
git diff --check
bash -n scripts/ops/clawops/docker-image-rollout.sh
pnpm check
```

TypeScript/runtime edits:

```bash
pnpm check
OPENCLAW_TEST_PROFILE=low OPENCLAW_TEST_SERIAL_GATEWAY=1 pnpm test -- <path-or-filter>
```

Before asking to land broad changes:

```bash
pnpm check
OPENCLAW_TEST_PROFILE=low OPENCLAW_TEST_SERIAL_GATEWAY=1 pnpm test
```

Run `pnpm build` when a change can affect build output, packaging, lazy-loading/module boundaries, or published surfaces.

## Production Deploy Boundary

Production deploys should be launched from ACP/local operator machines, not Codex Cloud.

Preferred access pattern:

1. Work in Codex Cloud on a branch.
2. Commit/push or open PR from Cloud.
3. Resume locally through ACP on this Mac or the Mac mini.
4. Pull/review the branch locally.
5. Deploy from the local trusted machine using Twingate SSH.

Local deploy command shape:

```bash
scripts/ops/clawops/docker-image-rollout.sh \
  --remote openclaw-droplet \
  --version <version> \
  --rollback-version <previous-version> \
  --targets clawops,shibot,gumnut,remy
```

## Twingate Remote Access

Twingate is the preferred access layer for the droplet from trusted local machines.

Recommended local SSH config:

```sshconfig
Host openclaw-droplet
  HostName <twingate-resource-dns-or-ip>
  User sreeopsadmin
  IdentitiesOnly yes
  IdentityFile ~/.ssh/<operator-key>
```

Use this alias in local runbooks:

```bash
ssh openclaw-droplet 'sudo docker ps'
scripts/ops/clawops/docker-image-rollout.sh --remote openclaw-droplet --version <version> --skip-rollout
```

Do not assume Codex Cloud can join Twingate. Treat Cloud as a code/build/test VM unless a future task explicitly validates Twingate inside that environment and documents the risk.

## Cloud Task Startup Prompt

Use this when starting a Codex Cloud task from mobile:

```text
Work in the OpenClaw repo only. Treat this as a Codex Cloud coding/QA environment, not a production deploy host. Read AGENTS.md and scripts/ops/clawops/CODEX-CLOUD-READY.md first. Make scoped repo changes, run appropriate validation, and leave deploy/runbook steps for ACP/local Mac over Twingate.
```

## Repo Hygiene Targets

- Keep deployment scripts parameterized and secret-free.
- Keep runbooks generic except for private ops notes under `scripts/ops/clawops/`.
- Avoid committing live config, phone numbers, tokens, or container `.env` files.
- Prefer timestamped Markdown notes for each real upgrade drill.
- Keep Cloud setup fast; move expensive validation into task specific commands.
