# Bentley

Bentley records Solana token profiles, refreshes market metrics, evaluates token
activity, and can notify Telegram channels when tokens match YAML-defined rules.

## Runtime configuration

The application expects these environment variables outside test:

- `SUSPICIOUS_TERMS_FILE_PATH`: optional path to the suspicious terms text file.
- `NOTIFIERS_FILE_PATH`: optional path to the YAML notifier definitions.
- `SNIPERS_FILE_PATH`: optional path to the YAML sniper definitions.
- `DATABASE_PATH`: optional sqlite database path override for runtime/release.
- `TELEGRAM_BOT_TOKEN`: required when `NOTIFIERS_FILE_PATH` is set.

In development, `.env` is loaded automatically. In production releases,
environment variables must be set by the host process manager or shell before
starting `_build/prod/rel/bentley/bin/bentley`.

For local development, start from the committed template:

```bash
cp dev.example.env .env
```

`dev.example.env` is for local development only. Server deploys use
`ops/bentley.env.example` to create `/etc/bentley/bentley.env`.

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

## Production release

The recommended deployment approach uses `ops/deploy.sh`, which is an idempotent
script that handles first-time server bootstrap and all subsequent deploys. The
templates in `ops/` provide the env file and systemd unit.

### Deploy

`ops/deploy.sh` is the single entry point for both first-time setup and ongoing
deploys. It is idempotent — safe to re-run.

On first run it will:
1. Create the `bentley` service user if missing.
2. Create `/etc/bentley/bentley.env` from the template and exit, prompting you to fill in secrets.
3. Install the systemd unit from `ops/bentley.service.example` if missing and enable it.
4. Create the `DATABASE_PATH` parent directory with correct ownership.
5. Create empty files for any configured `SUSPICIOUS_TERMS_FILE_PATH`, `NOTIFIERS_FILE_PATH`, `SNIPERS_FILE_PATH` that are missing.
6. Pull latest code, build the release, run migrations, restart the service.

First-time setup:

```bash
# Clone repository.
sudo mkdir -p /opt/bentley
sudo chown "$USER":"$USER" /opt/bentley
git clone <REPO_URL> /opt/bentley

# Run deploy — will create env file from template and stop on first run.
cd /opt/bentley
./ops/deploy.sh

# Edit env file with real values.
sudo nano /etc/bentley/bentley.env

# Run again — this time it builds, migrates, and starts the service.
./ops/deploy.sh
```

Every subsequent deploy is the same single command:

```bash
cd /opt/bentley && ./ops/deploy.sh
```

Recommended (explicit update + deploy):

```bash
cd /opt/bentley
git pull --ff-only origin main
./ops/deploy.sh
```

`ops/deploy.sh` already updates from origin internally. The explicit `git pull`
step is optional, but useful when you want to review update output before build.

### Configure the server env file

All runtime configuration lives in `/etc/bentley/bentley.env`. The deploy script
creates this file from `ops/bentley.env.example` on first run, then stops so you
can fill in real values before proceeding.

All variables in the env file:

| Variable | Required | Description |
|---|---|---|
| `DATABASE_PATH` | yes | Absolute path to the SQLite database file |
| `TELEGRAM_BOT_TOKEN` | when `NOTIFIERS_FILE_PATH` is set | Telegram bot token |
| `SUSPICIOUS_TERMS_FILE_PATH` | no | Path to suspicious terms text file |
| `NOTIFIERS_FILE_PATH` | no | Path to notifiers YAML file |
| `SNIPERS_FILE_PATH` | no | Path to snipers YAML file |
| `JUPITER_API_KEY` | no | Jupiter API key for sniper buy/sell |
| `SOLANA_RPC_URL` | no | Solana RPC URL (defaults to mainnet-beta public) |
| `SOLANA_WALLET_<id>` | per sniper wallet | Private key for each configured wallet |

Example `/etc/bentley/bentley.env`:

```bash
DATABASE_PATH=/var/lib/bentley/bentley.db
SUSPICIOUS_TERMS_FILE_PATH=/etc/bentley/suspicious_terms.txt
NOTIFIERS_FILE_PATH=/etc/bentley/notifiers.yaml
SNIPERS_FILE_PATH=/etc/bentley/snipers.yaml
TELEGRAM_BOT_TOKEN=123456:replace_me
JUPITER_API_KEY=replace_me
SOLANA_RPC_URL=https://api.mainnet-beta.solana.com
SOLANA_WALLET_main=replace_me
```

The parent directory of `DATABASE_PATH` must exist and be owned by the service
user. The deploy script creates it automatically, but you can also create it
manually if needed:

```bash
sudo mkdir -p /var/lib/bentley
sudo chown bentley:bentley /var/lib/bentley
sudo chmod 750 /var/lib/bentley
```

### deploy.sh variables (all optional)

| Variable | Default | Description |
|---|---|---|
| `APP_DIR` | `/opt/bentley` | Repo root on the server |
| `BRANCH` | `main` | Git branch to deploy |
| `SERVICE_NAME` | `bentley` | systemd service name |
| `SERVICE_USER` | `bentley` | OS user to run the service |
| `SERVICE_GROUP` | `bentley` | OS group for the service |
| `ENV_FILE` | `/etc/bentley/bentley.env` | Path to the server env file |
| `SERVICE_FILE` | `/etc/systemd/system/bentley.service` | Path to the systemd unit |
| `SERVICE_TEMPLATE` | `$APP_DIR/ops/bentley.service.example` | Template for the systemd unit |
| `ENV_TEMPLATE` | `$APP_DIR/ops/bentley.env.example` | Template for the env file |

> `dev.example.env` is for local development only (creates `.env`). Never point
> `ENV_FILE` at `dev.example.env` or `.env` — deploy will reject it.

### Starting manually (without systemd)

If you need to start the release from a shell directly:

```bash
set -a
source /etc/bentley/bentley.env
set +a
cd /opt/bentley
_build/prod/rel/bentley/bin/bentley start
```

### Service logs and remote IEx

Check current service status:

```bash
sudo systemctl status bentley --no-pager
```

Follow live logs from systemd journal:

```bash
sudo journalctl -u bentley -f
```

Show recent logs:

```bash
sudo journalctl -u bentley -n 200 --no-pager
```

Open a remote IEx shell on the running release:

```bash
/opt/bentley/_build/prod/rel/bentley/bin/bentley remote
```

Inside remote IEx, list currently active tokens (latest 20):

```elixir
import Ecto.Query

Bentley.Repo.all(
  from(t in Bentley.Schema.Token,
    where: t.active == true,
    order_by: [desc: t.updated_at],
    limit: 20,
    select: %{token_address: t.token_address, name: t.name, updated_at: t.updated_at}
  )
)
```

Quick node health checks:

```bash
/opt/bentley/_build/prod/rel/bentley/bin/bentley pid
/opt/bentley/_build/prod/rel/bentley/bin/bentley rpc "IO.inspect(node())"
```

Quick runtime config checks from server shell:

```bash
# List loaded notifier IDs
/opt/bentley/_build/prod/rel/bentley/bin/bentley rpc "defs = Bentley.Notifiers.loaded_definitions(); IO.inspect(Enum.map(defs, & &1.id), label: \"notifiers\")"

# List loaded sniper IDs
/opt/bentley/_build/prod/rel/bentley/bin/bentley rpc "defs = Bentley.Snipers.loaded_definitions(); IO.inspect(Enum.map(defs, & &1.id), label: \"snipers\")"

# Show suspicious terms count currently cached in ETS
/opt/bentley/_build/prod/rel/bentley/bin/bentley rpc "patterns = case :ets.lookup(:bentley_suspicious_terms_cache, :patterns) do [{:patterns, v}] -> v; _ -> [] end; IO.inspect(length(patterns), label: \"suspicious_terms_count\")"
```

### Sync notifier/sniper YAML + suspicious terms and reload

If you keep `notifiers.yaml`, `snipers.yaml`, and `suspicious_terms.txt` in the
project root locally, you can push only those files to the server and reload
them without rebuilding the release.

Ensure runtime paths in `/etc/bentley/bentley.env` point to the target directory
on the server, for example:

```bash
NOTIFIERS_FILE_PATH=/etc/bentley/notifiers.yaml
SNIPERS_FILE_PATH=/etc/bentley/snipers.yaml
SUSPICIOUS_TERMS_FILE_PATH=/etc/bentley/suspicious_terms.txt
```

Then from your local machine, run one of these:

```bash
./ops/sync-config.sh user@your-server
```

```powershell
.\ops\sync-config.ps1 user@your-server
```

Both scripts sync the three files to the server and install them with correct
permissions (`root:bentley 640`), then trigger a live reload on the running
release - no restart required.

Optional overrides:

| Variable | Default |
|---|---|
| `SERVER_CONFIG_DIR` | `/etc/bentley` |
| `APP_RELEASE_BIN` | `/opt/bentley/_build/prod/rel/bentley/bin/bentley` |
| `SERVICE_GROUP` | `bentley` |

## Notification troubleshooting

### Inspect a token's current metrics

If a token is not being picked up by a notifier, check its stored metrics by name:

```bash
/opt/bentley/_build/prod/rel/bentley/bin/bentley rpc "import Ecto.Query; t = Bentley.Repo.one(from t in Bentley.Schema.Token, where: t.name == \"TOKEN_NAME\", limit: 1); IO.inspect(t, label: \"token\")"
```

Replace `TOKEN_NAME` with the actual token name (case-sensitive). You can also match by `t.token_address` instead of `t.name`.

### Find which suspicious patterns matched a token name

If a token's `inactivity_reason` is `suspicious_name`, run this to see exactly which patterns triggered it:

```bash
/opt/bentley/_build/prod/rel/bentley/bin/bentley rpc "name = \"TOKEN_NAME\"; patterns = case :ets.lookup(:bentley_suspicious_terms_cache, :patterns) do [{:patterns, v}] -> v; _ -> [] end; matched = Enum.filter(patterns, &String.match?(name, &1)); IO.inspect(Enum.map(matched, &inspect/1), label: \"matched_patterns\")"
```

Replace `TOKEN_NAME` with the token name.

### Find latest tokens marked inactive by suspicious terms

If you want the most recent tokens flagged by suspicious terms (`inactivity_reason = suspicious_name`), run this in IEx:

```elixir
import Ecto.Query

Bentley.Repo.all(
  from(t in Bentley.Schema.Token,
    where: t.active == false and t.inactivity_reason == "suspicious_name",
    order_by: [desc: t.inserted_at],
    limit: 20,
    select: %{name: t.name, token_address: t.token_address, last_checked_at: t.last_checked_at}
  )
)
```
