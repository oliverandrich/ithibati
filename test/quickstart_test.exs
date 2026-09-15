defmodule Ithibati.QuickstartTest do
  @moduledoc """
  Every line of code the README shows appears in the setup guide.

  `README.md` shows the touchpoints — a line from the schema, a line from the router, a callback
  — so that somebody deciding whether to use Ithibati can see its shape. `docs/getting_started.md`
  is where those lines live in whole files. Neither reader sees the other page, so the code
  appears twice, and a consumer copies code.

  Line by line rather than block by block, because the README quotes fragments now: a whole-block
  comparison would force it to show whole modules again, which is the thing it stopped doing.
  """
  use ExUnit.Case, async: true

  @guide File.read!("docs/getting_started.md")
  @readme File.read!("README.md")

  # Punctuation a dozen lines end in, which would match anywhere and prove nothing.
  @trivial ["end", "do", "]", "}", ")", "|>"]

  @lines ~r/^```elixir\n(.*?)^```$/ms
         |> Regex.scan(@readme)
         |> Enum.flat_map(fn [_, block] -> String.split(block, "\n") end)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == "" or &1 in @trivial))

  test "every line of code in the README appears in the setup guide" do
    refute @lines == [], "no code found at all — this test would pass vacuously"

    for line <- @lines do
      assert String.contains?(@guide, line),
             "README.md shows this line and docs/getting_started.md does not:\n\n    #{line}"
    end
  end
end
