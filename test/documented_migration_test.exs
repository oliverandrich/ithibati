defmodule Ithibati.DocumentedMigrationTest do
  @moduledoc """
  Every call the suite's own migrations make is a call the documentation shows.

  The support migrations exist to exercise the documented path; that is worth nothing the moment
  the two drift. Initial setup lives in `docs/getting_started.md`; upgrades and historical
  migration pins are explained in `docs/configuration.md`.
  """
  use ExUnit.Case, async: true

  @support Path.wildcard("test/support/migrations/*.exs")

  test "every call the support migrations make appears in the guide verbatim" do
    guide = File.read!("docs/getting_started.md") <> File.read!("docs/configuration.md")

    calls =
      @support
      |> Enum.flat_map(&Regex.scan(~r/Ithibati\.Migration\.\w+\([^)]*\)/, File.read!(&1)))
      |> List.flatten()
      |> Enum.uniq()

    names =
      calls
      |> Enum.map(&(&1 |> String.split(".") |> Enum.at(2) |> String.split("(") |> hd()))
      |> Enum.uniq()
      |> Enum.sort()

    assert names == ["down", "up"],
           "expected an up and a down call, found: #{inspect(calls)}"

    for call <- calls do
      assert String.contains?(guide, call),
             "the setup and configuration guides do not show `#{call}`"
    end
  end
end
