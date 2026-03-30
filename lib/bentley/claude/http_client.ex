defmodule Bentley.Claude.HTTPClient do
  @moduledoc false

  @behaviour Bentley.Claude.Client
  @messages_url "https://api.anthropic.com/v1/messages"
  @model "claude-haiku-4-5-20251001"
  @connect_timeout_ms 3_000
  @receive_timeout_ms 10_000

  @impl true
  def real_person_name?(token_name) when is_binary(token_name) do
    case api_key() do
      key when is_binary(key) and key != "" ->
        request_headers = [
          {"x-api-key", key},
          {"anthropic-version", "2023-06-01"},
          {"content-type", "application/json"}
        ]

        request_body = %{
          model: @model,
          max_tokens: 4,
          temperature: 0,
          messages: [
            %{
              role: "user",
              content:
                "Is this string composed of realistic first name and last name, fit for a human individual: \"#{token_name}\" strict format: \"Yes\" or \"No\""
            }
          ]
        }

        case Req.post(@messages_url, [headers: request_headers, json: request_body] ++ req_options()) do
          {:ok, %{status: 200, body: body}} ->
            body
            |> answer_text()
            |> parse_yes_no()

          {:ok, %{status: status, body: body}} ->
            {:error, {:unexpected_response, status, body}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :missing_api_key}
    end
  end

  defp answer_text(%{"content" => content}) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> nil
    end)
  end

  defp answer_text(_), do: nil

  defp parse_yes_no(answer) when is_binary(answer) do
    normalized = answer |> String.trim() |> String.downcase()

    cond do
      normalized == "yes" -> {:ok, true}
      normalized == "no" -> {:ok, false}
      String.starts_with?(normalized, "yes") -> {:ok, true}
      String.starts_with?(normalized, "no") -> {:ok, false}
      true -> {:error, {:unexpected_answer, normalized}}
    end
  end

  defp parse_yes_no(_), do: {:error, :missing_answer}

  defp api_key do
    Application.get_env(:bentley, :claude_api_key)
  end

  defp req_options do
    [
      connect_options: [timeout: @connect_timeout_ms],
      receive_timeout: @receive_timeout_ms
    ]
  end
end
