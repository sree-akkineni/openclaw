# Clawops Heartbeat Checklist

Run every heartbeat cycle:

1. Confirm gateway reachable and healthy.
2. Check connector liveness and channel probe state.
3. Check memory and swap pressure thresholds.
4. If pressure high, keep noncritical heavy workflows paused.
5. Verify latest release watcher status and pending canary jobs.
6. Verify no missing required secrets for operational integrations.
7. Append a compact status note to operator digest trail.

When degraded:

- Run self-heal sequence before reboot consideration:
  1. restart affected service
  2. restart gateway and connectors
  3. rerun smoke suite
- Reboot only when the full self-heal sequence fails.
