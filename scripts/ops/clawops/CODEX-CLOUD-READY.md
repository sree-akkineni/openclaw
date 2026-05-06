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
2. For live ops, verify SSH access to `sreeopsadmin@10.108.0.2`.
3. Run read-only state first:

```bash
npm view openclaw version dist-tags --json
ssh sreeopsadmin@10.108.0.2 'sudo docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"'
```

4. For upgrade work, use canary-only first:

```bash
scripts/ops/clawops/docker-image-rollout.sh \
  --remote sreeopsadmin@10.108.0.2 \
  --version <version> \
  --skip-rollout
```

5. Write notes back to repo before ending the session.

## What Still Blocks Fully Smooth Cloud Ops

- Live secrets and SSH are host-bound. Codex Cloud needs explicit SSH/key access or a remote operator bridge.
- Some ops checks are noisy under concurrent probe load; avoid parallel heavy smoke plus health sweeps.
- The legacy multi-target smoke URL mode has false-negative timeouts and should not be used as the only gate.
- Release automation is partially npm-update-oriented; Docker compose deployments need image-tag-aware promotion.

## Repo Hygiene Targets

- Keep deployment scripts parameterized and secret-free.
- Keep runbooks generic except for private ops notes under `scripts/ops/clawops/`.
- Avoid committing live config, phone numbers, tokens, or container `.env` files.
- Prefer timestamped Markdown notes for each real upgrade drill.
