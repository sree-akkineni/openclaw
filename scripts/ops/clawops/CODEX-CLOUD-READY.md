# Codex Cloud Readiness Notes

## Goal

Make the OpenClaw ops work easy to resume from Codex Cloud or another device without depending on chat memory.

## Current Good State

- Repo has file-backed ops artifacts under `scripts/ops/clawops/`.
- Upgrade evidence and process notes are now committed to repo docs rather than only chat.
- `docker-image-rollout.sh` provides a repeatable entrypoint for image-based droplet upgrades.
- Stream C memory work remains local and inspectable under `scripts/ops/clawops/stream-c/`.

## Recommended Codex Cloud Workflow

1. Start from this repo path and read:
   - `scripts/ops/clawops/RUNBOOK.md`
   - `scripts/ops/clawops/UPGRADE-NOTES-2026-05-06.md`
   - `scripts/ops/clawops/ROADMAP.md`
2. For live ops, verify SSH access through Twingate. Prefer a stable SSH alias over a raw IP.
3. Run read-only state first:

```bash
npm view openclaw version dist-tags --json
ssh openclaw-droplet 'sudo docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"'
```

4. For upgrade work, use canary-only first:

```bash
scripts/ops/clawops/docker-image-rollout.sh \
  --remote openclaw-droplet \
  --version <version> \
  --skip-rollout
```

5. Write notes back to repo before ending the session.

## Codex Cloud Setup Boundary

Codex Cloud setup is not fully repo-local. The initial cloud environment must be created from the ChatGPT/Codex web UI because it requires:

- ChatGPT/Codex access for the workspace.
- GitHub connection through the ChatGPT GitHub Connector.
- Repository selection/authorization.
- Optional environment internet-access settings.
- Optional workspace admin toggles/RBAC if this is an Enterprise workspace.

Repo-local work we can do from here:

- Keep `AGENTS.md` current for Codex instructions.
- Keep `scripts/ops/clawops/` runbooks and rollout scripts current.
- Add Team Config under `.codex/` if we want shared Codex defaults.
- Provide exact setup scripts and validation commands for the cloud environment.
- Keep cloud-safe prompts and task plans in repo docs.

Web UI work the operator must do:

1. Open `https://chatgpt.com/codex`.
2. Connect GitHub using the ChatGPT GitHub Connector.
3. Allow the `openclaw` repository.
4. Create/select the Codex Cloud environment for this repo.
5. Configure setup commands and internet access.
6. Add only non-sensitive environment variables needed for builds/tests.
7. Keep live droplet secrets out of Codex Cloud unless there is a specific task requiring them.

## Recommended Codex Cloud Environment

Use Codex Cloud primarily for repo work, not direct production operations.

Setup command:

```bash
corepack enable
pnpm install
```

Validation commands:

```bash
pnpm check
pnpm test -- --runInBand
bash -n scripts/ops/clawops/docker-image-rollout.sh
```

Internet access:

- Enable setup-time internet for dependency installation.
- Keep agent runtime internet off by default.
- If runtime internet is needed for release research, restrict to `registry.npmjs.org`, `github.com`, `api.github.com`, `ghcr.io`, `docs.openclaw.ai`, and OpenAI docs domains.

Secrets:

- Do not store droplet root tokens or live OpenClaw gateway tokens in Codex Cloud.
- Prefer Twingate-mediated SSH from a local operator environment for production changes.
- If Cloud must trigger live ops later, create a narrow deploy key or one-purpose SSH principal with command restrictions and document it before use.

## Twingate Remote Access

Twingate is the preferred access layer for the droplet.

Recommended local SSH config:

```sshconfig
Host openclaw-droplet
  HostName <twingate-resource-dns-or-ip>
  User sreeopsadmin
  IdentitiesOnly yes
  IdentityFile ~/.ssh/<operator-key>
```

Use this alias in runbooks:

```bash
ssh openclaw-droplet 'sudo docker ps'
scripts/ops/clawops/docker-image-rollout.sh --remote openclaw-droplet --version <version> --skip-rollout
```

Do not assume Codex Cloud can join the private Twingate network. Treat Cloud as a repo/build/test environment unless Twingate access is explicitly validated inside that cloud environment.

## What Still Blocks Fully Smooth Cloud Ops

- Live secrets and Twingate/SSH are host-bound. Codex Cloud needs explicit network validation before it can operate the droplet directly.
- Some ops checks are noisy under concurrent probe load; avoid parallel heavy smoke plus health sweeps.
- The legacy multi-target smoke URL mode has false-negative timeouts and should not be used as the only gate.
- Release automation is partially npm-update-oriented; Docker compose deployments need image-tag-aware promotion.

## Repo Hygiene Targets

- Keep deployment scripts parameterized and secret-free.
- Keep runbooks generic except for private ops notes under `scripts/ops/clawops/`.
- Avoid committing live config, phone numbers, tokens, or container `.env` files.
- Prefer timestamped Markdown notes for each real upgrade drill.
