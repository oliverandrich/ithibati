defmodule IthibatiOpenWeb.LayoutsTest do
  @moduledoc """
  The one place where the browser is told the same rule as the server.

  A `pattern` attribute that disagrees with `Ithibati.Schema.Identifier.username_format/0` refuses
  names the server would take, or waves through names it will not, and neither failure says
  anything — so the derivation that keeps them in step is pinned rather than trusted.
  """
  use ExUnit.Case, async: true

  alias Ithibati.Schema.Identifier
  alias IthibatiOpenWeb.Layouts

  # HTML anchors `pattern` implicitly; this is what the browser compiles it to.
  defp as_browser_sees_it do
    Regex.compile!("\\A(?:" <> Layouts.username_pattern() <> ")\\z")
  end

  test "the pattern the form carries answers exactly what the library answers" do
    for value <- [
          "alice",
          "a",
          "_",
          "0123456789",
          String.duplicate("a", 30),
          String.duplicate("a", 31),
          "alice.smith",
          "alice-smith",
          "alice smith",
          "Alice",
          "\u0430lice",
          "alice@example.com",
          "",
          "alice\n"
        ] do
      assert Regex.match?(as_browser_sees_it(), value) ==
               Regex.match?(Identifier.username_format(), value),
             "the form and the server disagree about #{inspect(value)}"
    end
  end

  # The guard on the derivation itself: `pattern` is ECMAScript, which has no `\\A`, so a stray
  # anchor would not merely be untidy — the browser would refuse to compile the attribute and stop
  # validating anything at all, silently.
  test "and carries no anchor the browser cannot compile" do
    refute Layouts.username_pattern() =~ ~r/\\[Az]/
  end
end
