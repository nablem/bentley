defmodule Bentley.Telegram.Client do
  @moduledoc """
  Behaviour and dispatch module for Telegram message delivery.
  """

  @callback send_message(String.t(), String.t()) :: :ok | {:error, term()}

  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  def send_message(channel, message) when is_binary(channel) and is_binary(message) do
    impl().send_message(channel, message)
  end

  defp impl do
    Application.get_env(:bentley, :telegram_client, Bentley.Telegram.HTTPClient)
  end
end
