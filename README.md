# Bentley

Bentley records Solana token profiles, refreshes market metrics, evaluates token
activity, and can notify Telegram channels when tokens match YAML-defined rules.

## Runtime configuration

The application expects these environment variables outside test:

- `SUSPICIOUS_TERMS_FILE_PATH`: path to the suspicious terms text file.
- `NOTIFIERS_FILE_PATH`: optional path to the YAML notifier definitions.
- `TELEGRAM_BOT_TOKEN`: required when `NOTIFIERS_FILE_PATH` is set.

## Notifier configuration

Notifier definitions are loaded from YAML at startup and can be reloaded at runtime
with `Bentley.Notifiers.reload/0`.

Example:

```yaml
notifiers:
  - id: fresh-volume
    enabled: true
    telegram_channel: "@my_channel"
    poll_interval_seconds: 60
    max_tokens_per_run: 10
    criteria:
      age_hours:
        min: 0
        max: 24
      volume_1h:
        min: 1000
      market_cap:
        min: 10000
        max: 500000
```

Supported criteria keys are `age_hours`, `market_cap`, `liquidity`, `volume_1h`,
`volume_6h`, `volume_24h`, `change_1h`, `change_6h`, `change_24h`, `boost`, and `ath`.
Each criterion accepts `min`, `max`, or both.

Each notifier has its own `telegram_channel`. Multiple notifiers may point to the
same Telegram channel, or to different channels.

Each notifier sends a given token at most once after a successful Telegram delivery.
If Telegram delivery fails, the token remains eligible for retry on the next poll.

