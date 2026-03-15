import Config

if config_env() == :dev do
  Dotenvy.source([".env"])
end

dexscreener_api_key = System.get_env("DEXSCREENER_API_KEY")

if is_nil(dexscreener_api_key) and config_env() != :test do
  raise """
  DEXSCREENER_API_KEY environment variable is required!

  In development, add it to .env file:
    DEXSCREENER_API_KEY=your_key_here

  In production, set it as an environment variable.
  """
end

config :bentley,
  dexscreener_api_key: dexscreener_api_key
