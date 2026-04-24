# Stream D Channel Strategy (Shibot Production Default)

## Decision

Production default for Shibot is **Twilio voice/SMS**.

WhatsApp Web dedicated-account linking remains a supported secondary path for teams that explicitly need WhatsApp chats, but it is not the default production surface.

## Comparison: WhatsApp Web Dedicated Account vs Twilio Voice/SMS

| Dimension                                         | WhatsApp Web Dedicated Account                                 | Twilio Voice/SMS                                                   |
| ------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------ |
| Built-in support in current OpenClaw flow         | Supported through WhatsApp Web/Baileys QR linking              | Supported through voice/SMS channel plugins and Twilio credentials |
| Provisioning model                                | Requires a real WhatsApp account linked by QR from a phone app | Fully API credential based; no QR session                          |
| Session stability risk                            | Higher (device relink/logout/QR expiry operational events)     | Lower (provider API auth + webhook/runtime availability)           |
| Headless remote ops fit                           | Weaker due to QR/device dependency                             | Strong; designed for remote automation and recovery                |
| Recovery time objective under account drift       | Usually slower because relink requires phone/operator action   | Usually faster: rotate token/number config and restart checks      |
| Suitability for "digital-only number" requirement | Not met by built-in WhatsApp Web channel                       | Met for voice/SMS use cases                                        |
| WhatsApp-native conversation support              | Yes                                                            | No (unless a future Twilio/Meta WhatsApp adapter is built)         |

## Recommendation and Tradeoffs

Recommended default: **Twilio voice/SMS** for production reliability and recoverability.

Tradeoffs accepted:

- You lose native WhatsApp chat continuity in the default path.
- You gain lower operational toil, faster recovery, and better compatibility with unattended host operations.
- If WhatsApp-native messaging becomes mandatory, implement a separate Twilio/Meta WhatsApp API adapter as a future stream instead of overloading the built-in Web-linking path.

## Implemented Artifacts for This Decision

- `scripts/ops/clawops/channel-strategy.md` (this decision record)
- `scripts/ops/clawops/validate-whatsapp-channel.sh` (channel readiness validator with:
  - default mode `twilio-voice-sms`
  - explicit `whatsapp-web` mode
  - probe parsing, env-key checks, and deterministic fixture-based validation support)

## Operational Recovery Runbook Steps (Exact Commands)

### A) Twilio voice/SMS default path recovery

1. Load env and validate Twilio channel readiness:

```bash
set -a; [ -f /opt/clawops/.env ] && . /opt/clawops/.env; set +a
/opt/clawops/scripts/validate-whatsapp-channel.sh --mode twilio-voice-sms --env-file /opt/clawops/.env
```

2. If validation fails due to credentials, rotate/fix:

```bash
openclaw config set channels.voice-call.twilio.accountSid "$TWILIO_ACCOUNT_SID"
openclaw config set channels.voice-call.twilio.authToken "$TWILIO_AUTH_TOKEN"
openclaw config set channels.voice-call.twilio.fromNumber "$TWILIO_FROM_NUMBER"
```

3. Restart gateway and re-probe channels:

```bash
pkill -9 -f openclaw-gateway || true
nohup openclaw gateway run --bind loopback --port 18789 --force >/tmp/openclaw-gateway.log 2>&1 &
openclaw channels status --probe
```

4. Re-run smoke checks:

```bash
/opt/clawops/scripts/validate-runtime.sh
/opt/clawops/scripts/smoke-suite.sh
```

5. Confirm operator digest/status state:

```bash
tail -n 80 "$HOME/.openclaw/clawops/logs/operator-digest.jsonl"
cat "$HOME/.openclaw/clawops/state/release-watch.json"
```

### B) WhatsApp Web dedicated-account recovery (non-default fallback)

1. Validate WhatsApp probe status:

```bash
/opt/clawops/scripts/validate-whatsapp-channel.sh --mode whatsapp-web --env-file /opt/clawops/.env
```

2. If unlinked, relink with dedicated account QR flow from a real WhatsApp app account.

3. Re-check channel probe and smoke:

```bash
openclaw channels status --probe
/opt/clawops/scripts/smoke-suite.sh
```

4. If repeated relink churn occurs, cut back to Twilio default path and open a follow-up stream for a Twilio/Meta WhatsApp API adapter.
