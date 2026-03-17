defmodule Bentley.Notifiers.Worker do
  @moduledoc false

  use GenServer
  require Logger

  import Ecto.Query

  alias Bentley.Notifiers.Criteria
  alias Bentley.Notifiers.Definition
  alias Bentley.Notifiers.Formatter
  alias Bentley.Repo
  alias Bentley.Schema.NotificationDelivery
  alias Bentley.Schema.Token
  alias Bentley.TelegramClient

  def start_link(%Definition{} = definition) do
    GenServer.start_link(__MODULE__, definition, name: via_tuple(definition.id))
  end

  def child_spec(%Definition{} = definition) do
    %{
      id: {__MODULE__, definition.id},
      start: {__MODULE__, :start_link, [definition]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @spec deliver_notifications(Definition.t(), NaiveDateTime.t()) ::
          {:ok, %{matched: non_neg_integer(), sent: non_neg_integer(), failed: non_neg_integer()}}
  def deliver_notifications(%Definition{} = definition, now \\ current_time()) do
    tokens = matching_tokens(definition, now)

    result =
      Enum.reduce(tokens, %{matched: length(tokens), sent: 0, failed: 0}, fn token, acc ->
        case deliver_token(definition, token, now) do
          :ok -> %{acc | sent: acc.sent + 1}
          {:error, _reason} -> %{acc | failed: acc.failed + 1}
        end
      end)

    {:ok, result}
  end

  @spec matching_tokens(Definition.t(), NaiveDateTime.t()) :: [struct()]
  def matching_tokens(%Definition{} = definition, now \\ current_time()) do
    Token
    |> where([t], t.active == true)
    |> join(:left, [t], d in NotificationDelivery,
      on: d.token_address == t.token_address and d.notifier_id == ^definition.id
    )
    |> where([_t, d], is_nil(d.id))
    |> select([t, _d], t)
    |> Repo.all()
    |> Enum.filter(&Criteria.match?(&1, definition.criteria, now))
    |> Enum.sort_by(&sort_key(&1, now), :asc)
    |> Enum.take(definition.max_tokens_per_run)
  end

  def via_tuple(id), do: {:via, Registry, {Bentley.Notifiers.Registry, id}}

  @impl true
  def init(%Definition{} = definition) do
    schedule_poll(definition.poll_interval_ms)
    {:ok, definition}
  end

  @impl true
  def handle_info(:poll, %Definition{} = definition) do
    case deliver_notifications(definition) do
      {:ok, %{matched: matched, sent: sent, failed: failed}} when matched > 0 ->
        Logger.info(
          "[Notifiers] #{definition.id} evaluated #{matched} tokens, sent #{sent}, failed #{failed}"
        )

      {:ok, _result} ->
        :ok
    end

    schedule_poll(definition.poll_interval_ms)
    {:noreply, definition}
  end

  defp deliver_token(definition, token, now) do
    message = Formatter.format(definition, token, now)

    case TelegramClient.send_message(definition.telegram_channel, message) do
      :ok ->
        record_delivery(definition, token, message, now)

      {:error, reason} ->
        Logger.error(
          "[Notifiers] Failed to send token #{token.token_address} for #{definition.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp record_delivery(definition, token, message, now) do
    %NotificationDelivery{}
    |> NotificationDelivery.changeset(%{
      notifier_id: definition.id,
      token_address: token.token_address,
      telegram_channel: definition.telegram_channel,
      message_text: message,
      sent_at: now
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:notifier_id, :token_address]
    )
    |> case do
      {:ok, _delivery} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp sort_key(token, now) do
    case Criteria.age_in_hours(token, now) do
      nil -> 1.0e308
      age_hours -> age_hours
    end
  end

  defp current_time do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end
end
