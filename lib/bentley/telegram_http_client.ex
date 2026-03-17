defmodule Bentley.TelegramHTTPClient do
  @moduledoc false

  @behaviour Bentley.TelegramClient

  @impl true
  def send_message(channel, message) when is_binary(channel) and is_binary(message) do
    case bot_token() do
      token when is_binary(token) and token != "" ->
        send_request(token, channel, message)

      _ ->
        {:error, :missing_bot_token}
    end
  end

  defp send_request(token, channel, message) do
    url = api_base_url() <> "/bot" <> token <> "/sendMessage"

    case Req.post(url,
           json: %{
             chat_id: channel,
             text: message,
             disable_web_page_preview: true
           }
         ) do
      {:ok, %{status: 200, body: %{"ok" => true}}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_response, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp api_base_url do
    Application.get_env(:bentley, :telegram_api_base_url, "https://api.telegram.org")
  end

  defp bot_token do
    Application.get_env(:bentley, :telegram_bot_token)
  end
end
