defmodule Ithibati.DocumentedMigrationTest do
  @moduledoc """
  The migration in the README and the one the suite runs are the same two lines.

  The support migration exists to exercise the documented path; that is worth nothing the moment the
  two drift, and a drift of exactly that kind — an unpinned `up()` against a pinned one — is what a
  review found here.
  """
  use ExUnit.Case, async: true

  @support "test/support/migrations/20260912000100_add_ithibati.exs"

  test "every call the support migration makes appears in the README verbatim" do
    readme = File.read!("README.md")

    calls =
      @support
      |> File.read!()
      |> then(&Regex.scan(~r/Ithibati\.Migration\.\w+\([^)]*\)/, &1))
      |> List.flatten()

    assert length(calls) == 2, "expected an up and a down call, found: #{inspect(calls)}"

    for call <- calls do
      assert String.contains?(readme, call), "the README does not show `#{call}`"
    end
  end
end
