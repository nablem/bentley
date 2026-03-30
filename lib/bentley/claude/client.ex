defmodule Bentley.Claude.Client do
  @moduledoc false

  @callback real_person_name?(String.t()) :: {:ok, boolean()} | {:error, term()}

  @spec real_person_name?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def real_person_name?(token_name) when is_binary(token_name) do
    impl().real_person_name?(token_name)
  end

  defp impl do
    Application.get_env(:bentley, :claude_client, Bentley.Claude.HTTPClient)
  end
end
