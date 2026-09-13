defmodule Ithibati.DesignDecisionsTest do
  @moduledoc """
  The README lists the design decisions and links into `docs/design.md` by anchor. Both halves rot
  silently: a decision added to the document is simply absent from the list, and a renamed heading
  leaves a link that still looks like one.

  It went wrong exactly that way — decision 7 shipped in one commit and reached the README in the
  next, noticed by hand rather than by anything here.
  """
  use ExUnit.Case, async: true

  @readme File.read!("README.md")
  @design File.read!("docs/design.md")

  @headings Regex.scan(~r/^## (\d+)\. (.+)$/m, @design)
            |> Enum.map(fn [_, n, text] -> {n, text} end)
  # The numbered list alone, not every mention: a decision named in some paragraph would otherwise
  # satisfy "is it listed", which is the drift this file is for.
  @linked Regex.scan(~r/^\d+\. \[[^\]]+\]\(docs\/design\.md#([\w-]+)\)$/m, @readme)
          |> Enum.map(fn [_, anchor] -> anchor end)

  # A decision written without a number is invisible to everything below.
  test "the decisions are numbered, and numbered without gaps" do
    numbers = Enum.map(@headings, fn {number, _text} -> String.to_integer(number) end)

    assert numbers == Enum.to_list(1..length(numbers)//1),
           "the headings in docs/design.md are #{inspect(numbers)}"
  end

  # The list went from six to eight in one commit and the sentence above it still said six, which no
  # amount of checking the list would have caught. A prose count is a copy of something countable,
  # so the rule is that there is not one.
  test "and no prose spells out how many there are" do
    for file <- ["README.md", "CLAUDE.md", "docs/design.md"] do
      refute File.read!(file) =~ ~r/\b(three|four|five|six|seven|eight|nine|ten)\s+decisions\b/i,
             "#{file} spells out a count of the decisions, which will be wrong at the next one"
    end
  end

  test "every link into the document reaches a heading that exists" do
    anchors = MapSet.new(@headings, fn {number, text} -> anchor("#{number}. #{text}") end)

    for link <- @linked do
      assert link in anchors, "README links to ##{link}, which no heading in docs/design.md makes"
    end
  end

  test "and every decision is listed in the README" do
    for {number, text} <- @headings do
      assert anchor("#{number}. #{text}") in @linked,
             "decision #{number} (#{text}) is in docs/design.md and not in the README's list"
    end
  end

  # GitHub's rule, which is what resolves these links: lower case, punctuation dropped, spaces to
  # hyphens.
  defp anchor(heading) do
    heading
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/u, "")
    |> String.trim()
    |> String.replace(~r/\s+/, "-")
  end
end
