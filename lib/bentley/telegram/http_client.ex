defmodule Bentley.Telegram.HTTPClient do
  @moduledoc false

  @behaviour Bentley.Telegram.Client

  @impl true
  def send_message(channel, message) when is_binary(channel) and is_binary(message) do
    case bot_token() do
      token when is_binary(token) and token != "" ->
        url = api_base_url() <> "/bot" <> token <> "/sendMessage"

        post_json(url, %{
          chat_id: channel,
          text: message,
          disable_web_page_preview: true,
          parse_mode: "HTML"
        })

      _ ->
        {:error, :missing_bot_token}
    end
  end

  @impl true
  def send_photo(channel, photo_url, caption)
      when is_binary(channel) and is_binary(photo_url) and is_binary(caption) do
    case bot_token() do
      token when is_binary(token) and token != "" ->
        url = api_base_url() <> "/bot" <> token <> "/sendPhoto"

        post_json(url, %{
          chat_id: channel,
          photo: photo_url,
          caption: caption,
          parse_mode: "HTML"
        })

      _ ->
        {:error, :missing_bot_token}
    end
  end

  defp post_json(url, body) do
    case Req.post(url, json: body) do
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
