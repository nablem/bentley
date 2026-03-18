import Config

if config_env() == :dev do
  Dotenvy.source!([".env"]) |> System.put_env()
end

suspicious_terms_file_path = System.get_env("SUSPICIOUS_TERMS_FILE_PATH")
notifiers_file_path = System.get_env("NOTIFIERS_FILE_PATH")
snipers_file_path = System.get_env("SNIPERS_FILE_PATH")
telegram_bot_token = System.get_env("TELEGRAM_BOT_TOKEN")

blank_to_nil = fn
  value when is_binary(value) ->
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end

  value ->
    value
end

suspicious_terms_file_path = blank_to_nil.(suspicious_terms_file_path)
notifiers_file_path = blank_to_nil.(notifiers_file_path)
snipers_file_path = blank_to_nil.(snipers_file_path)
telegram_bot_token = blank_to_nil.(telegram_bot_token)

if is_binary(suspicious_terms_file_path) and config_env() != :test and
     not File.exists?(suspicious_terms_file_path) do
  raise """
  SUSPICIOUS_TERMS_FILE_PATH points to a missing file:
    #{suspicious_terms_file_path}

  Make sure the file exists and the path is correct.
  Example:
    SUSPICIOUS_TERMS_FILE_PATH=priv/repo/suspicious_terms.txt
  """
end

if is_binary(notifiers_file_path) and config_env() != :test and
     not File.exists?(notifiers_file_path) do
  raise """
  NOTIFIERS_FILE_PATH points to a missing file:
    #{notifiers_file_path}

  Make sure the file exists and the path is correct.
  Example:
    NOTIFIERS_FILE_PATH=notifiers.yml
  """
end

if is_binary(snipers_file_path) and config_env() != :test and
     not File.exists?(snipers_file_path) do
  raise """
  SNIPERS_FILE_PATH points to a missing file:
    #{snipers_file_path}

  Make sure the file exists and the path is correct.
  Example:
    SNIPERS_FILE_PATH=snipers.yml
  """
end

if is_binary(notifiers_file_path) and config_env() != :test and
     is_nil(telegram_bot_token) do
  raise """
  TELEGRAM_BOT_TOKEN environment variable is required when NOTIFIERS_FILE_PATH is set.

  In development, add it to .env file:
    TELEGRAM_BOT_TOKEN=123456:telegram_bot_token

  In production, set it as an environment variable.
  """
end

config :bentley,
  suspicious_terms_file_path: suspicious_terms_file_path,
  notifiers_file_path: notifiers_file_path,
  snipers_file_path: snipers_file_path,
  telegram_bot_token: telegram_bot_token
