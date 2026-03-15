defmodule Bentley.RateLimiterTest do
  use ExUnit.Case

  alias Bentley.RateLimiter

  defp reset_limiter! do
    :sys.replace_state(RateLimiter, fn _ -> %{last_request_at: nil} end)
  end

  test "second execution is delayed to enforce one request per second" do
    reset_limiter!()

    RateLimiter.execute(fn -> :ok end)

    started_at = System.monotonic_time(:millisecond)
    RateLimiter.execute(fn -> :ok end)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms >= 900
  end

  test "concurrent executions are spaced by about one second" do
    reset_limiter!()

    timestamps =
      1..3
      |> Enum.map(fn _ ->
        Task.async(fn ->
          RateLimiter.execute(fn -> System.monotonic_time(:millisecond) end)
        end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))
      |> Enum.sort()

    diffs_ms =
      timestamps
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)

    assert Enum.all?(diffs_ms, &(&1 >= 900))
  end
end
