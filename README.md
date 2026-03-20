# Bentley

Bentley records Solana token profiles, refreshes market metrics, evaluates token
activity, and can notify Telegram channels when tokens match YAML-defined rules.

## Runtime configuration

The application expects these environment variables outside test:

- `SUSPICIOUS_TERMS_FILE_PATH`: optional path to the suspicious terms text file.
- `NOTIFIERS_FILE_PATH`: optional path to the YAML notifier definitions.
- `SNIPERS_FILE_PATH`: optional path to the YAML sniper definitions.
- `TELEGRAM_BOT_TOKEN`: required when `NOTIFIERS_FILE_PATH` is set.

In development, `.env` is loaded automatically. In production releases,
environment variables must be set by the host process manager or shell before
starting `bin/bentley`.

For Solana sniper executor integrations (buy/sell + wallet capital checks), use:

- `JUPITER_API_KEY`: Jupiter API key used for quote/swap requests.
- `SOLANA_WALLET_<wallet_id>`: private key for each sniper wallet ID.
- `SOLANA_RPC_URL`: optional Solana RPC URL override (defaults to mainnet-beta public RPC).

Example mapping:

- `wallet_ids: [main]` in `snipers.yaml` uses `SOLANA_WALLET_main`.
- `wallet_ids: [main, secondary]` in `snipers.yaml` uses both `SOLANA_WALLET_main` and `SOLANA_WALLET_secondary`.

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

## Sniper configuration

Sniper definitions are loaded from YAML at startup and can be reloaded at runtime
with `Bentley.Snipers.reload/0`.

Example:

```yaml
snipers:
  - id: early-microcap-sniper
    enabled: true
    trigger_on_notifiers:
      - fresh-volume
    wallet_ids:
      - main
      - secondary
    poll_interval_seconds: 120
    buy_config:
      enabled: true
      position_size_usd: 100
      slippage_bps: 50
      min_wallet_usdc: 250
    exit_tiers:
      - market_cap: 50000
        sell_percent: 25
      - market_cap: 100000
        sell_percent: 75
    safety:
      max_slippage_percent: 15
      max_position_count: 10
      stop_loss_percent: null
      timeout_hours: null
```

`stop_loss_percent` and `timeout_hours` are disabled by default when omitted.
`wallet_ids` supports one or more wallets per sniper definition. A notifier trigger
attempts the same buy flow independently for each wallet in the list.
For backward compatibility, a single `wallet_id` is still accepted and treated as
`wallet_ids: [wallet_id]`.
`buy_config.min_wallet_usdc` is optional and, when set, blocks buys unless the
configured wallet has at least that USDC balance.
If multiple snipers match the same notifier event for the same wallet, candidates
are prioritized by `buy_config.min_wallet_usdc` (highest first), and fallback to
lower thresholds only when the higher one fails with insufficient wallet USDC.
This priority logic only applies to overlapping wallet+notifier matches; wallets
with a single matching sniper are handled normally.
`buy_config.position_size_usd` is interpreted as Solana USDC amount in human
units (for example, `200` means `200.0` USDC). Before buy execution it is
converted to base units for Jupiter/Solana (`200` -> `200_000_000`).
By default, snipers use the live Jupiter executor for buy/sell operations.
Exit tier `sell_percent` values are percentages of the initial buy amount.
Exit tiers with `market_cap` below a position's entry market cap are skipped.
On each poll, open positions are reconciled against on-chain wallet balance for the token:
- if on-chain balance is lower than managed remaining units, managed remaining is reduced;
- if on-chain balance is zero, the position is closed;
- if on-chain balance is higher (manual extra buy), extra units are treated as unmanaged and are not auto-sold.
For each eligible tier, sell units are computed from cumulative initial-buy targets minus already sold units,
then bounded by managed remaining units.
If omitted, `poll_interval_seconds` defaults to `120` (2 minutes).

### Manual live buy command

You can trigger a one-off live buy directly from CLI:

```bash
mix sniper.buy <wallet_id> <token_address> <amount_usdc>
```

Example (`200` means `200.0` USDC):

```bash
mix sniper.buy mywallet DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263 200
```

Optional flags:

```bash
mix sniper.buy mywallet <token_address> 200 --slippage-bps 50 --max-slippage-percent 15
```

### Manual live sell command

You can trigger a one-off live sell directly from CLI:

```bash
mix sniper.sell <wallet_id> <token_address> <units>
```

`<units>` is raw token base units (on-chain amount, not UI-decimal amount).

Example:

```bash
mix sniper.sell mywallet DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263 150000
```

To sell the full wallet token balance for that token:

```bash
mix sniper.sell mywallet <token_address> --all
```

Optional flags:

```bash
mix sniper.sell mywallet <token_address> --all --slippage-bps 50 --max-slippage-percent 15
```

### Force an immediate exit-tier sell (IEx test helper)

If you want to test sell notifications immediately, do not set `initial_units` to `0`.
Exit-tier sell size is based on the initial buy units, so `initial_units: 0` produces
`0` sell units and no sell trade.

Instead, force the position `entry_market_cap` to `0` and make sure the token
`market_cap` is above your first exit tier.

1. Run IEx with the app:

```bash
iex -S mix
```

2. In IEx, run:

```elixir
import Ecto.Query

sniper_id = "early-microcap-sniper"
wallet_id = "main"
token_address = "PASTE_TOKEN_ADDRESS"

position =
  Bentley.Repo.get_by!(Bentley.Schema.SniperPosition,
    sniper_id: sniper_id,
    wallet_id: wallet_id,
    token_address: token_address,
    status: "open"
  )

# Force all tiers to be considered above entry.
Bentley.Repo.update_all(
  from(p in Bentley.Schema.SniperPosition, where: p.id == ^position.id),
  set: [entry_market_cap: 0.0]
)

# Ensure token market cap is above your target exit tier(s).
Bentley.Repo.update_all(
  from(t in Bentley.Schema.Token, where: t.token_address == ^token_address),
  set: [market_cap: 250_000.0]
)

# Process immediately (no need to wait for poll interval).
definition = Enum.find(Bentley.Snipers.loaded_definitions(), &(&1.id == sniper_id))
Bentley.Snipers.PositionManager.process_open_positions(definition)
```

### Close open positions in bulk (IEx helper)

If you need to force-close positions for testing or recovery, you can close all
currently open positions for one sniper, or all open positions in the database.

1. Run IEx with the app:

```bash
iex -S mix
```

2. In IEx, run one of the following:

```elixir
import Ecto.Query

now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
sniper_id = "early-microcap-sniper"

# Close all OPEN positions for one sniper.
Bentley.Repo.update_all(
  from(p in Bentley.Schema.SniperPosition,
    where: p.status == "open" and p.sniper_id == ^sniper_id
  ),
  set: [status: "closed", remaining_units: 0.0, closed_at: now]
)

# Close ALL OPEN positions across all snipers.
Bentley.Repo.update_all(
  from(p in Bentley.Schema.SniperPosition, where: p.status == "open"),
  set: [status: "closed", remaining_units: 0.0, closed_at: now]
)
```

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

#### Loading production environment variables

Use a dedicated production env file (for example, `/etc/bentley/bentley.env`) and
load it before starting the release.

Example file:

```bash
SUSPICIOUS_TERMS_FILE_PATH=/opt/bentley/current/suspicious_terms.txt
NOTIFIERS_FILE_PATH=/opt/bentley/current/notifiers.yaml
SNIPERS_FILE_PATH=/opt/bentley/current/snipers.yaml
TELEGRAM_BOT_TOKEN=123456:replace_me
JUPITER_API_KEY=replace_me
SOLANA_WALLET_main=replace_me
SOLANA_RPC_URL=https://api.mainnet-beta.solana.com
```

Recommended permissions:

```bash
sudo chown root:root /etc/bentley/bentley.env
sudo chmod 600 /etc/bentley/bentley.env
```

If using `systemd`, add this to the service:

```ini
[Service]
EnvironmentFile=/etc/bentley/bentley.env
WorkingDirectory=/opt/bentley/current
ExecStart=/opt/bentley/current/bin/bentley start
ExecStop=/opt/bentley/current/bin/bentley stop
Restart=always
```

Apply service changes:

```bash
sudo systemctl daemon-reload
sudo systemctl restart bentley
sudo systemctl status bentley
```

If starting manually from a shell:

```bash
set -a
source /etc/bentley/bentley.env
set +a
./bin/bentley start
```

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

