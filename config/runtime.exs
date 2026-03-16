import Config

if config_env() == :dev do
  Dotenvy.source!([".env"]) |> System.put_env()
end

dexscreener_api_key = System.get_env("DEXSCREENER_API_KEY")
suspicious_terms_file_path = System.get_env("SUSPICIOUS_TERMS_FILE_PATH")

if is_nil(dexscreener_api_key) and config_env() != :test do
  raise """
  DEXSCREENER_API_KEY environment variable is required!

  In development, add it to .env file:
    DEXSCREENER_API_KEY=your_key_here

  In production, set it as an environment variable.
  """
end

if is_nil(suspicious_terms_file_path) and config_env() != :test do
  raise """
  SUSPICIOUS_TERMS_FILE_PATH environment variable is required!

  In development, add it to .env file:
    SUSPICIOUS_TERMS_FILE_PATH=priv/repo/suspicious_terms.txt

  In production, set it as an environment variable.
  """
end

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

config :bentley,
  dexscreener_api_key: dexscreener_api_key,
  suspicious_terms_file_path: suspicious_terms_file_path
