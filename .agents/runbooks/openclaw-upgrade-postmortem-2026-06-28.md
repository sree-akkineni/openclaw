# OpenClaw Droplet OOM And Auth Drift Postmortem (June 28, 2026)

## Scope
Postmortem for the `clawdbot-gateway` incident where live agents became unreliable and the host had to be recovered through the DigitalOcean console.

## What happened
- `clawops-gateway` hit repeated cgroup OOM kills during the prior boot.
- The kernel OOM evidence mapped to Docker container `8ddd395065843fde94d35963af6d71587da08bfb05f070641bc0db081bb46907`, which is `clawops-gateway`.
- Around the same window, `clawops` also logged repeated `active-memory` failures for `openai-http`, pointing at `/root/.openclaw/agents/main/agent/openclaw-agent.sqlite`.
- SSH access was unavailable until the host was recovered through the DO console, `sshd` was restarted, and the operator key was restored.

## What we verified after recovery
- Host memory was healthy after reboot (`~7.8 GiB` RAM total, low load, no active swap pressure beyond residue from the earlier event).
- All four gateway containers returned to `healthy`.
- `openclaw models status --check` passed in all four containers after recovery.
- `main` was still on `2026.6.8` while `clawops`, `remy`, and `gumnut` were on `2026.6.9`.

## Likely incident shape
- Primary incident: container-level memory exhaustion inside `clawops-gateway`, not whole-host exhaustion at the time of post-recovery inspection.
- Secondary incident: auth-path drift for the `active-memory` sub-agent on `clawops` before reboot. This was not reproducing after recovery, but it appeared in the failure window and should not be treated as noise.
- Additional drift: stale live-state manifest and mixed runtime versions made it harder to trust the usual upgrade verifier output.

## Lessons
- Treat container cgroup OOMs and host-wide pressure as separate failure classes.
- Preserve or collect the previous-boot journal before assuming the reboot erased the root cause.
- `openclaw models status --check` is a good post-recovery auth gate and should be part of droplet triage.
- Keep the live-state manifest current enough that it reflects real images and runtime versions, or the verifier becomes misleading during incidents.

## Follow-up
- Added `scripts/droplet-health-monitor.sh` plus systemd timer units for recurring host-side snapshots.
- Updated the live-state manifest to current images/runtime versions and the June 28 findings.
