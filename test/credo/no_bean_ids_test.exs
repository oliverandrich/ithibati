defmodule Ithibati.Credo.NoBeanIdsTest do
  @moduledoc """
  The check has to be seen firing on hand-written source, not only staying quiet on a clean tree — a
  check that always returns the empty list passes every "no issues here" assertion there is.
  """
  use Credo.Test.Case

  alias Ithibati.Credo.NoBeanIds

  # Built the way the check builds its pattern, so this file does not report itself either.
  @prefix "ithi" <> "bati-"

  defp check(source),
    do: source |> to_source_file("lib/ithibati/thing.ex") |> run_check(NoBeanIds)

  test "an id in a comment is reported" do
    "# See #{@prefix}a1b2 for why.\ndefmodule X do\nend\n"
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == @prefix <> "a1b2"
      assert issue.line_no == 1
    end)
  end

  # The most likely violation there is: an id at the end of a docstring, with nothing after it but
  # the closing quote.
  test "an id at the end of a docstring is reported" do
    "defmodule X do\n  @moduledoc \"Decided in #{@prefix}a1b2\"\nend\n"
    |> check()
    |> assert_issue()
  end

  test "an id ending a sentence is still an id" do
    "defmodule X do\n  @moduledoc \"Decided in #{@prefix}9zzz.\"\nend\n"
    |> check()
    |> assert_issue()
  end

  # Bean files are named `<id>--<slug>.md`, so this is the form the reference is most naturally
  # written in — and the one a lookahead refusing every hyphen reads as a longer name.
  test "a bean file path is reported" do
    "# See .beans/#{@prefix}kuj3--bring-across.md\ndefmodule X do\nend\n"
    |> check()
    |> assert_issue(&assert(&1.trigger == @prefix <> "kuj3"))
  end

  test "every id on a line is reported, not just the first" do
    assert [one, two] = check("# Both #{@prefix}aaaa and #{@prefix}bbbb.\ndefmodule X do\nend\n")
    assert one.trigger == @prefix <> "aaaa"
    assert two.trigger == @prefix <> "bbbb"
  end

  test "a longer name that merely starts the same way is left alone" do
    "defmodule X do\n  @topic \"#{@prefix}events\"\nend\n"
    |> check()
    |> refute_issues()
  end

  test "a filename is left alone" do
    "defmodule X do\n  @file \"#{@prefix}logo.avif\"\nend\n"
    |> check()
    |> refute_issues()
  end

  # Accepted, and pinned so it is a decision rather than a surprise: four characters is four
  # characters, and the pattern cannot tell an id from a short word. If such a name is ever wanted,
  # `# credo:disable-for-next-line` is the escape.
  test "a four-letter word after the prefix is reported too" do
    "defmodule X do\n  @topic \"#{@prefix}core\"\nend\n"
    |> check()
    |> assert_issue()
  end
end
