# Bentley

Bentley records Solana token profiles, refreshes market metrics, evaluates token
activity, and can notify Telegram channels when tokens match YAML-defined rules.

## Runtime configuration

The application expects these environment variables outside test:

- `SUSPICIOUS_TERMS_FILE_PATH`: optional path to the suspicious terms text file.
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

  - id: follow-up
    enabled: true
    telegram_channel: "@my_channel"
    depends_on: fresh-volume
    poll_interval_seconds: 60
    max_tokens_per_run: 10
    criteria:
      age_hours:
        min: 0
        max: 24
```

Supported criteria keys are `age_hours`, `market_cap`, `liquidity`, `volume_1h`,
`volume_6h`, `volume_24h`, `change_1h`, `change_6h`, `change_24h`, `boost`, and `ath`.
Each criterion accepts `min`, `max`, or both.

Each notifier has its own `telegram_channel`. Multiple notifiers may point to the
same Telegram channel, or to different channels.

Notifiers can depend on other notifiers through `depends_on` (string or list of
notifier IDs). A dependent notifier only sends a token after all referenced
notifiers have already sent that token successfully.

Each notifier sends a given token at most once after a successful Telegram delivery.
If Telegram delivery fails, the token remains eligible for retry on the next poll.

## Live reload and inspection

### Development with IEx

To run the app in development and keep the node reachable from another shell,
start it as a named node:

```bash
iex --sname bentley --cookie devcookie -S mix
```

In that shell, you can confirm the node name with:

```elixir
node()
```

From a second shell, attach a remote shell to the running node:

```bash
iex --sname admin --cookie devcookie --remsh bentley@YOUR_HOSTNAME
```

From the remote shell, reload the suspicious terms cache:

```elixir
Bentley.SuspiciousTermsCache.reload()
```

You can also inspect token state directly through the running Repo:

```elixir
token = Bentley.Repo.get_by(Bentley.Schema.Token, token_address: "PASTE_TOKEN_ADDRESS")
Map.take(token, [:token_address, :name, :active, :inactivity_reason])
```

This is useful for testing the retroactive suspicious-term flow:

1. Start the app with `iex --sname bentley --cookie devcookie -S mix`.
2. Pick an active token from the logs.
3. Confirm in the remote shell that it is currently `active: true`.
4. Edit the suspicious terms file so one term matches that token's name.
5. Run `Bentley.SuspiciousTermsCache.reload()` from the remote shell.
6. Query the token again and verify it became `active: false` with `inactivity_reason: "suspicious_name"`.

### Production release

If the app is deployed as a release, build it with:

```bash
MIX_ENV=prod mix release
```

Start the release:

```bash
_build/prod/rel/bentley/bin/bentley start
```

Reload the suspicious terms cache without opening a shell:

```bash
_build/prod/rel/bentley/bin/bentley rpc "Bentley.SuspiciousTermsCache.reload()"
```

Attach a remote shell for inspection:

```bash
_build/prod/rel/bentley/bin/bentley remote
```

Then query the database through the live node:

```elixir
token = Bentley.Repo.get_by(Bentley.Schema.Token, token_address: "PASTE_TOKEN_ADDRESS")
Map.take(token, [:token_address, :name, :active, :inactivity_reason])
```

For a release deployment, the operational flow is the same as in development:
edit the suspicious terms file on disk, run the reload command, then inspect the
token through `Bentley.Repo` to confirm the token became inactive.

### Docker

If the release runs in a Docker container, use `docker exec` to reach the node:

Start the container (usually via docker-compose or docker run):

```bash
docker run -d --name bentley_app -e SUSPICIOUS_TERMS_FILE_PATH=/app/suspicious_terms.txt bentley_image
```

Reload the suspicious terms cache without opening a shell:

```bash
docker exec bentley_app bin/bentley rpc "Bentley.SuspiciousTermsCache.reload()"
```

Attach a remote shell for inspection:

```bash
docker exec -it bentley_app bin/bentley remote
```

Then use the same IEx commands as the native release:

```elixir
Bentley.SuspiciousTermsCache.reload()
token = Bentley.Repo.get_by(Bentley.Schema.Token, token_address: "PASTE_TOKEN_ADDRESS")
Map.take(token, [:token_address, :name, :active, :inactivity_reason])
```

The operational workflow is identical to the native release—only the invocation changes
from `bin/bentley` to `docker exec <container_name> bin/bentley`.

