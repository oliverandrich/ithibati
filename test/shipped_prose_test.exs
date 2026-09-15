defmodule Ithibati.ShippedProseTest do
  @moduledoc """
  The half of the no-bean-ids rule that Credo cannot hold: it reads Elixir sources, and the rule also
  covers the prose. What makes prose worth covering is that it ships — so the list of files comes
  from `package(files:)`, through `Ithibati.Prose`, rather than from a second hand-written copy of
  it, and a directory added to the package is under the rule without anybody remembering this
  file.

  Held against the check's own pattern for the same reason: two patterns drift, and the one that
  drifts is the one nobody runs.
  """
  use ExUnit.Case, async: true

  alias Ithibati.Credo.NoBeanIds

  # Credo already reads every `.ex`/`.exs`, so scanning them again here would only slow the suite.
  @shipped Ithibati.Prose.shipped()

  test "the files this reads are the ones that ship" do
    assert "README.md" in @shipped
    assert "LICENSE" in @shipped
    assert Enum.any?(@shipped, &(&1 =~ "docs/"))
  end

  test "no bean id appears in the prose that ships" do
    offenders =
      for path <- @shipped,
          {line, line_no} <- Enum.with_index(File.stream!(path), 1),
          [match] <- Regex.scan(NoBeanIds.pattern(), line),
          do: "#{path}:#{line_no}: #{match}"

    assert offenders == [],
           "bean ids belong in the beans, not in files that ship:\n  " <>
             Enum.join(offenders, "\n  ")
  end
end
