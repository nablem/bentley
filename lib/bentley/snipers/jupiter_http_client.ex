defmodule Bentley.Snipers.JupiterHttpClient do
  @moduledoc false

  @callback get(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback post(binary(), keyword()) :: {:ok, map()} | {:error, term()}
end
