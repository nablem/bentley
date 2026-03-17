defmodule Bentley.SuspiciousTermsCacheTest do
  use ExUnit.Case, async: false

  alias Bentley.SuspiciousTermsCache

  setup do
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
