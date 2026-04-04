# Clawops Standing Orders

## Program: Release Detection and Distilled Alerts

Authority:

- Monitor new OpenClaw releases.
- Send immediate alert plus daily distilled digest to the configured operator DM.

Trigger:

- Hourly release watcher.
- Daily digest timer.

Execution Rules:

1. Detect latest published OpenClaw version.
2. If new version appears, send immediate alert with version and change summary.
3. Distill release notes by workflow categories:
   - gateway and channels
   - PDF workflows
   - Playwright and browser automation
   - Himalaya and Gmail auth/connectivity
   - deployment/runtime stability
4. Log all detection and delivery outcomes.

Escalation:

- If release metadata retrieval fails twice consecutively, send degraded-health alert.

## Program: Canary then Promote Update Pipeline

Authority:

- Run canary update and validation.
- Promote only after green validation.
- Roll back canary on failure.

Trigger:

- New release detection or manual operator trigger.

Execution Rules:

1. Snapshot runtime state before update.
2. Run update dry run.
3. Apply canary update.
4. Run smoke suite sequentially.
5. Promote only if all checks pass.
6. On failure, restore snapshot and apply rollback path.

Escalation:

- Promotion is blocked if any smoke check fails.
- Include failure diagnosis and next action in operator alert.

## Program: Reliability and Capacity Guardrails (4GB)

Authority:

- Pause noncritical heavy tasks under memory pressure.
- Prioritize gateway and connectors.

Trigger:

- Every pipeline run and weekly hygiene cycle.

Execution Rules:

1. Evaluate available memory and swap usage.
2. If under threshold, pause noncritical heavy checks.
3. Keep release pipeline queued and serialized.
4. Resume heavy tasks once pressure clears.

Escalation:

- If pressure persists for 2 hours, send sustained-degradation alert.

## Program: Secret and Credential Continuity

Authority:

- Back up and restore secret-bearing runtime files from local snapshots.
- Run missing-secret audits for required integrations.

Trigger:

- Pre-apply baseline, pre-update, and weekly hygiene.

Execution Rules:

1. Snapshot credentials and secret payload files.
2. Validate required secret env vars and auth profiles.
3. Restore from snapshot when wipe/drift is detected.
4. Verify Notion/shibot credentials after recovery.

Escalation:

- If required credentials remain missing after recovery, send immediate incident alert.

## Guardrail: Self-Heal then Reboot

Allowed without additional approval:

- install/update
- process restart
- gateway restart
- connector restart

Conditionally allowed:

- reboot only after staged recovery fails in this order:
  1. service restart
  2. gateway and connector restart
  3. smoke recheck

Required after conditional reboot:

- include an escalation note in the same operator digest event.

Disallowed without explicit operator command:

- destructive bulk deletion
- mass credential resets
- unmanaged host-level destructive actions
