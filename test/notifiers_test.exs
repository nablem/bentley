defmodule Bentley.NotifiersTest do
  use ExUnit.Case, async: false

  import Mox

  alias Bentley.Notifiers
  alias Bentley.Notifiers.Definition
  alias Bentley.Notifiers.Loader
  alias Bentley.Notifiers.Worker
  alias Bentley.Repo
  alias Bentley.Schema.NotificationDelivery
  alias Bentley.Schema.Token

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Bentley.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Bentley.Repo, {:shared, self()})

    previous_path = Application.get_env(:bentley, :notifiers_file_path)
    previous_client = Application.get_env(:bentley, :telegram_client)

    Repo.delete_all(NotificationDelivery)
    Repo.delete_all(Token)

    Application.put_env(:bentley, :telegram_client, Bentley.Telegram.ClientMock)
    Application.put_env(:bentley, :notifiers_file_path, nil)
    :ok = Notifiers.reload()

    on_exit(fn ->
      Application.put_env(:bentley, :telegram_client, previous_client)
      Application.put_env(:bentley, :notifiers_file_path, previous_path)
      _ = Notifiers.reload()
    end)

    :ok
  end

  test "loader parses notifier definitions from yaml" do
    path =
      write_yaml!("""
      notifiers:
        - id: alpha
          enabled: true
          telegram_channel: "@alpha"
          poll_interval_seconds: 30
          max_tokens_per_run: 5
          criteria:
            age_hours:
              min: 1
              max: 24
            volume_1h:
              min: 1000
      """)

    assert {:ok,
            [
              %Definition{
                id: "alpha",
                enabled: true,
                telegram_channel: "@alpha",
                poll_interval_ms: 30_000,
                max_tokens_per_run: 5,
                criteria: %{
                  age_hours: %{min: 1, max: 24},
                  volume_1h: %{min: 1000, max: nil}
                }
              }
            ]} = Loader.load_from_file(path)
  end

  test "loader rejects duplicate notifier ids" do
    path =
      write_yaml!("""
      notifiers:
        - id: dup
          telegram_channel: "@one"
        - id: dup
          telegram_channel: "@two"
      """)

    assert {:error, {:duplicate_notifier_id, "dup"}} = Loader.load_from_file(path)
  end

  test "loader parses notifier dependencies" do
    path =
      write_yaml!("""
      notifiers:
        - id: first
          telegram_channel: "@first"
        - id: second
          telegram_channel: "@second"
          depends_on:
            - first
      """)

    assert {:ok,
            [
              %Definition{id: "first", depends_on_notifier_ids: []},
              %Definition{id: "second", depends_on_notifier_ids: ["first"]}
            ]} = Loader.load_from_file(path)
  end

  test "loader rejects unknown, self, and cyclic dependencies" do
    unknown_path =
      write_yaml!("""
      notifiers:
        - id: first
          telegram_channel: "@first"
          depends_on: missing
      """)

    assert {:error, {:unknown_dependency, "first", "missing"}} = Loader.load_from_file(unknown_path)

    self_path =
      write_yaml!("""
      notifiers:
        - id: first
          telegram_channel: "@first"
          depends_on: first
      """)

    assert {:error, {:self_dependency, "first"}} = Loader.load_from_file(self_path)

    cyclic_path =
      write_yaml!("""
      notifiers:
        - id: first
          telegram_channel: "@first"
          depends_on: second
        - id: second
          telegram_channel: "@second"
          depends_on: first
      """)

    assert {:error, {:cyclic_dependency, ["first", "second", "first"]}} =
             Loader.load_from_file(cyclic_path)
  end

  test "reload replaces workers when yaml definitions change" do
    path =
      write_yaml!("""
      notifiers:
        - id: alpha
          telegram_channel: "@alpha"
      """)

    Application.put_env(:bentley, :notifiers_file_path, path)

    assert :ok = Notifiers.reload()
    first_pid = Notifiers.worker_pid("alpha")
    assert is_pid(first_pid)

    File.write!(
      path,
      """
      notifiers:
        - id: alpha
          telegram_channel: "@beta"
      """
    )

    assert :ok = Notifiers.reload()
    second_pid = Notifiers.worker_pid("alpha")
    assert is_pid(second_pid)
    assert second_pid != first_pid
    assert :sys.get_state(second_pid).telegram_channel == "@beta"
  end

  test "deliver_notifications sends a matching token only once per notifier" do
    now = ~N[2026-03-17 12:00:00]

    insert_token!(%{
      token_address: "token-alpha",
      active: true,
      created_on_chain_at: ~N[2026-03-17 10:00:00],
      name: "Alpha",
      ticker: "ALP",
      volume_1h: 2_500.0,
      market_cap: 50_000.0,
      liquidity: 10_000.0
    })

    definition = %Definition{
      id: "alpha",
      telegram_channel: "@alpha",
      criteria: %{
        age_hours: %{min: 0, max: 24},
        volume_1h: %{min: 1_000, max: nil}
      }
    }

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@alpha", message ->
      assert message =~ "Alpha"
      assert message =~ "token-alpha"
      :ok
    end)

    assert {:ok, %{matched: 1, sent: 1, failed: 0}} = Worker.deliver_notifications(definition, now)
    assert Repo.aggregate(NotificationDelivery, :count, :id) == 1

    Bentley.Telegram.ClientMock
    |> deny(:send_message, 2)

    assert {:ok, %{matched: 0, sent: 0, failed: 0}} = Worker.deliver_notifications(definition, now)
    assert Repo.aggregate(NotificationDelivery, :count, :id) == 1
  end

  test "failed telegram deliveries remain eligible for retry" do
    now = ~N[2026-03-17 12:00:00]

    insert_token!(%{
      token_address: "token-retry",
      active: true,
      created_on_chain_at: ~N[2026-03-17 11:30:00],
      name: "Retry",
      ticker: "TRY",
      volume_1h: 5_000.0
    })

    definition = %Definition{
      id: "retry",
      telegram_channel: "@retry",
      criteria: %{
        age_hours: %{min: 0, max: 24},
        volume_1h: %{min: 1_000, max: nil}
      }
    }

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@retry", _message -> {:error, :timeout} end)

    assert {:ok, %{matched: 1, sent: 0, failed: 1}} = Worker.deliver_notifications(definition, now)
    assert Repo.aggregate(NotificationDelivery, :count, :id) == 0

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@retry", _message -> :ok end)

    assert {:ok, %{matched: 1, sent: 1, failed: 0}} = Worker.deliver_notifications(definition, now)
    assert Repo.aggregate(NotificationDelivery, :count, :id) == 1
  end

  test "dependent notifier sends only after prerequisite notifier sent the token" do
    now = ~N[2026-03-17 12:00:00]

    insert_token!(%{
      token_address: "token-dependent",
      active: true,
      created_on_chain_at: ~N[2026-03-17 11:00:00],
      name: "Dependent",
      ticker: "DEP",
      volume_1h: 5_000.0
    })

    prerequisite_definition = %Definition{
      id: "source",
      telegram_channel: "@source",
      criteria: %{age_hours: %{min: 0, max: 24}}
    }

    dependent_definition = %Definition{
      id: "target",
      telegram_channel: "@target",
      depends_on_notifier_ids: ["source"],
      criteria: %{age_hours: %{min: 0, max: 24}}
    }

    Bentley.Telegram.ClientMock
    |> deny(:send_message, 2)

    assert {:ok, %{matched: 0, sent: 0, failed: 0}} =
             Worker.deliver_notifications(dependent_definition, now)

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@source", _message -> :ok end)

    assert {:ok, %{matched: 1, sent: 1, failed: 0}} =
             Worker.deliver_notifications(prerequisite_definition, now)

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@target", _message -> :ok end)

    assert {:ok, %{matched: 1, sent: 1, failed: 0}} =
             Worker.deliver_notifications(dependent_definition, now)
  end

  test "different notifiers can notify the same token independently" do
    now = ~N[2026-03-17 12:00:00]

    insert_token!(%{
      token_address: "token-shared",
      active: true,
      created_on_chain_at: ~N[2026-03-17 11:00:00],
      name: "Shared",
      ticker: "SHR",
      volume_1h: 3_000.0
    })

    first_definition = %Definition{
      id: "first",
      telegram_channel: "@first",
      criteria: %{age_hours: %{min: 0, max: 24}}
    }

    second_definition = %Definition{
      id: "second",
      telegram_channel: "@second",
      criteria: %{age_hours: %{min: 0, max: 24}}
    }

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@first", _message -> :ok end)
    |> expect(:send_message, fn "@second", _message -> :ok end)

    assert {:ok, %{matched: 1, sent: 1, failed: 0}} = Worker.deliver_notifications(first_definition, now)
    assert {:ok, %{matched: 1, sent: 1, failed: 0}} = Worker.deliver_notifications(second_definition, now)

    assert Repo.aggregate(NotificationDelivery, :count, :id) == 2

    addresses_by_notifier =
      NotificationDelivery
      |> Repo.all()
      |> Enum.map(&{&1.notifier_id, &1.token_address})
      |> Enum.sort()

    assert addresses_by_notifier == [{"first", "token-shared"}, {"second", "token-shared"}]
  end

  test "different notifiers can share the same telegram channel" do
    now = ~N[2026-03-17 12:00:00]

    insert_token!(%{
      token_address: "token-same-channel",
      active: true,
      created_on_chain_at: ~N[2026-03-17 11:00:00],
      name: "Same Channel",
      ticker: "SAME",
      volume_1h: 3_000.0
    })

    first_definition = %Definition{
      id: "same-channel-first",
      telegram_channel: "@shared",
      criteria: %{age_hours: %{min: 0, max: 24}}
    }

    second_definition = %Definition{
      id: "same-channel-second",
      telegram_channel: "@shared",
      criteria: %{age_hours: %{min: 0, max: 24}}
    }

    Bentley.Telegram.ClientMock
    |> expect(:send_message, fn "@shared", _message -> :ok end)
    |> expect(:send_message, fn "@shared", _message -> :ok end)

    assert {:ok, %{matched: 1, sent: 1, failed: 0}} =
             Worker.deliver_notifications(first_definition, now)

    assert {:ok, %{matched: 1, sent: 1, failed: 0}} =
             Worker.deliver_notifications(second_definition, now)

    deliveries = Repo.all(NotificationDelivery)

    assert Enum.count(deliveries) == 2

    assert Enum.sort(Enum.map(deliveries, & &1.notifier_id)) == [
             "same-channel-first",
             "same-channel-second"
           ]

    assert Enum.uniq(Enum.map(deliveries, & &1.telegram_channel)) == ["@shared"]
  end

  defp insert_token!(attrs) do
    %Token{}
    |> Token.changeset(attrs)
    |> Repo.insert!()
  end

  defp write_yaml!(contents) do
    path = Path.join(System.tmp_dir!(), "notifiers_#{System.unique_integer([:positive])}.yml")
    File.write!(path, contents)

    on_exit(fn ->
      File.rm(path)
    end)

    path
  end
end
