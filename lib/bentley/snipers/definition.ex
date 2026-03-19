defmodule Bentley.Snipers.Definition do
  @moduledoc false

  @type exit_tier :: %{market_cap: number(), sell_percent: number()}

  @type buy_config :: %{
          enabled: boolean(),
          position_size_usd: number(),
      slippage_bps: pos_integer(),
      min_wallet_usdc: number() | nil
        }

  @type safety :: %{
          max_slippage_percent: number() | nil,
          max_position_count: pos_integer() | nil,
          stop_loss_percent: number() | nil,
          timeout_hours: pos_integer() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          enabled: boolean(),
          trigger_on_notifier_ids: [String.t()],
          wallet_ids: [String.t()],
          telegram_channel: String.t() | nil,
          poll_interval_ms: pos_integer(),
          buy_config: buy_config(),
          exit_tiers: [exit_tier()],
          safety: safety()
        }

  @default_buy_config %{
    enabled: true,
    position_size_usd: 100,
    slippage_bps: 50,
    min_wallet_usdc: nil
  }

  @default_safety %{
    max_slippage_percent: 15,
    max_position_count: 10,
    stop_loss_percent: nil,
    timeout_hours: nil
  }

  @enforce_keys [:id, :trigger_on_notifier_ids, :wallet_ids, :exit_tiers]
  defstruct id: nil,
            enabled: true,
            trigger_on_notifier_ids: [],
            wallet_ids: [],
            telegram_channel: nil,
            poll_interval_ms: :timer.minutes(2),
            buy_config: @default_buy_config,
            exit_tiers: [],
            safety: @default_safety

  @spec default_buy_config() :: buy_config()
  def default_buy_config, do: @default_buy_config

  @spec default_safety() :: safety()
  def default_safety, do: @default_safety
end
