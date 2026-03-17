defmodule Bentley.Notifiers.Definition do
  @moduledoc false

  @type metric ::
          :age_hours
          | :market_cap
          | :liquidity
          | :volume_1h
          | :volume_6h
          | :volume_24h
          | :change_1h
          | :change_6h
          | :change_24h
          | :boost
          | :ath

  @type range :: %{min: number() | nil, max: number() | nil}

  @type t :: %__MODULE__{
          id: String.t(),
          enabled: boolean(),
          telegram_channel: String.t(),
          depends_on_notifier_ids: [String.t()],
          poll_interval_ms: pos_integer(),
          max_tokens_per_run: pos_integer(),
          criteria: %{optional(metric()) => range()}
        }

  @enforce_keys [:id, :telegram_channel, :criteria]
  defstruct id: nil,
            enabled: true,
            telegram_channel: nil,
            depends_on_notifier_ids: [],
            poll_interval_ms: :timer.minutes(1),
            max_tokens_per_run: 20,
            criteria: %{}

  @metrics [
    :age_hours,
    :market_cap,
    :liquidity,
    :volume_1h,
    :volume_6h,
    :volume_24h,
    :change_1h,
    :change_6h,
    :change_24h,
    :boost,
    :ath
  ]

  @spec metrics() :: [metric()]
  def metrics, do: @metrics
end
