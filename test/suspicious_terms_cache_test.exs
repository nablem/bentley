defmodule Bentley.SuspiciousTermsCacheTest do
  use ExUnit.Case, async: false

  alias Bentley.Repo
  alias Bentley.Schema.Token
  alias Bentley.SuspiciousTermsCache

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Bentley.Repo)

    if pid = Process.whereis(Bentley.SuspiciousTermsCache) do
      Ecto.Adapters.SQL.Sandbox.allow(Bentley.Repo, self(), pid)
    end

    previous_path = Application.get_env(:bentley, :suspicious_terms_file_path)

    on_exit(fn ->
      Application.put_env(:bentley, :suspicious_terms_file_path, previous_path)
      :ok = SuspiciousTermsCache.reload()
    end)

    :ok
  end

  test "match?/1 uses configured file patterns" do
    path = write_suspicious_terms_file(["rug", "^scam", "dump$"])
    Application.put_env(:bentley, :suspicious_terms_file_path, path)
    :ok = SuspiciousTermsCache.reload()

    assert SuspiciousTermsCache.match?("mega rug launch")
    assert SuspiciousTermsCache.match?("scam alert")
    assert SuspiciousTermsCache.match?("hard dump")
    refute SuspiciousTermsCache.match?("clean project")
  end

  test "match?/1 applies word boundaries when expression is not anchored" do
    path = write_suspicious_terms_file(["rug"])
    Application.put_env(:bentley, :suspicious_terms_file_path, path)
    :ok = SuspiciousTermsCache.reload()

    assert SuspiciousTermsCache.match?("rug token")
    refute SuspiciousTermsCache.match?("drugcoin")
  end

  test "reload/0 updates cache when file content changes" do
    path = write_suspicious_terms_file(["rug"])
    Application.put_env(:bentley, :suspicious_terms_file_path, path)
    :ok = SuspiciousTermsCache.reload()

    assert SuspiciousTermsCache.match?("rug token")
    refute SuspiciousTermsCache.match?("scam token")

    File.write!(path, "scam\n")
    :ok = SuspiciousTermsCache.reload()

    refute SuspiciousTermsCache.match?("rug token")
    assert SuspiciousTermsCache.match?("scam token")
  end

  test "invalid regex lines are ignored while valid lines still work" do
    path = write_suspicious_terms_file(["(", "rug"])
    Application.put_env(:bentley, :suspicious_terms_file_path, path)
    :ok = SuspiciousTermsCache.reload()

    assert SuspiciousTermsCache.match?("rug token")
    refute SuspiciousTermsCache.match?("clean token")
  end

  test "match?/1 returns false when suspicious terms path is unset" do
    Application.put_env(:bentley, :suspicious_terms_file_path, nil)
    :ok = SuspiciousTermsCache.reload()

    refute SuspiciousTermsCache.match?("rug token")
  end

  test "reload/0 marks active tokens with suspicious names inactive" do
    path = write_suspicious_terms_file(["rug"])
    Application.put_env(:bentley, :suspicious_terms_file_path, path)

    token_address = "rug_token_#{System.unique_integer([:positive])}"

    %Token{}
    |> Token.changeset(%{token_address: token_address, name: "mega rug launch"})
    |> Repo.insert!()

    :ok = SuspiciousTermsCache.reload()

    token = Repo.get_by!(Token, token_address: token_address)
    assert token.active == false
    assert token.inactivity_reason == "suspicious_name"
  end

  test "reload/0 leaves non-suspicious active tokens untouched" do
    path = write_suspicious_terms_file(["rug"])
    Application.put_env(:bentley, :suspicious_terms_file_path, path)

    token_address = "clean_token_#{System.unique_integer([:positive])}"

    %Token{}
    |> Token.changeset(%{token_address: token_address, name: "clean project"})
    |> Repo.insert!()

    :ok = SuspiciousTermsCache.reload()

    token = Repo.get_by!(Token, token_address: token_address)
    assert token.active == true
    assert token.inactivity_reason == nil
  end

  test "reload/0 does not overwrite inactivity_reason of already-inactive tokens" do
    path = write_suspicious_terms_file(["rug"])
    Application.put_env(:bentley, :suspicious_terms_file_path, path)

    token_address = "inactive_rug_#{System.unique_integer([:positive])}"

    %Token{}
    |> Token.changeset(%{
      token_address: token_address,
      name: "rug coin",
      active: false,
      inactivity_reason: "low_liquidity"
    })
    |> Repo.insert!()

    :ok = SuspiciousTermsCache.reload()

    token = Repo.get_by!(Token, token_address: token_address)
    assert token.active == false
    assert token.inactivity_reason == "low_liquidity"
  end

  test "reload/0 ignores active tokens with nil names" do
    path = write_suspicious_terms_file(["rug"])
    Application.put_env(:bentley, :suspicious_terms_file_path, path)

    token_address = "nil_name_#{System.unique_integer([:positive])}"

    %Token{}
    |> Token.changeset(%{token_address: token_address})
    |> Repo.insert!()

    :ok = SuspiciousTermsCache.reload()

    token = Repo.get_by!(Token, token_address: token_address)
    assert token.active == true
  end

  defp write_suspicious_terms_file(lines) do
    file_path =
      Path.join(System.tmp_dir!(), "suspicious_terms_#{System.unique_integer([:positive])}.txt")

    File.write!(file_path, Enum.join(lines, "\n"))

    on_exit(fn ->
      File.rm(file_path)
    end)

    file_path
  end
end
