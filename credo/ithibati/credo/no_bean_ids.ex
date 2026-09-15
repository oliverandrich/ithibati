# SPDX-License-Identifier: MIT

defmodule Ithibati.Credo.NoBeanIds do
  use Credo.Check,
    id: "ITH002",
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Bean ids belong in the beans and in CLAUDE.md, which live and die with the tracker.

      The backlog may not outlive the release. An id left in the tree then points at nothing while
      still reading as authoritative, and it sends the next reader looking for a file that is not
      there. It matters more in a library than in an application, because these files are read by
      people with no access to the tracker at all.

      Write the reasoning the id stands for into the comment instead, or drop the reference — the
      sentence usually carries it already.
      """
    ]

  # After the `use` and not before it, which is the whole trick: `Credo.Check` writes a moduledoc
  # from its `explanations:` block, so an attribute set first is overwritten and one set afterwards
  # wins. Hidden because this check guards this repository and is not in the package — `mix docs`
  # runs in `dev`, where `elixirc_paths` includes `credo/`, so without this it gets a page on
  # hexdocs describing a rule nobody reading it can switch on.
  @moduledoc false

  # Assembled rather than written out, so this check does not report itself: what stands in the
  # source is the prefix followed by a quote, not by four more characters.
  @prefix "ithi" <> "bati-"

  # The second lookahead is what lets a bean *file path* through: those are named `<id>--<slug>.md`,
  # and refusing every following hyphen would read the `--` as a longer name. Four characters is
  # four characters, though, so a name like `<prefix>core` is reported too — accepted, and pinned in
  # the tests so it is a decision rather than a surprise.
  #
  # Credo reads Elixir sources, so this covers `lib/` and `test/`. The prose that ships is the other
  # half of the rule and is held by `Ithibati.ShippedProseTest`.
  @pattern Regex.compile!(@prefix <> "[a-z0-9]{4}(?![a-z0-9])(?!-[a-z0-9])(?!\\.[a-z]{2,5}\\b)")

  @doc "The pattern itself, so the other half of the rule is held against the same one."
  def pattern, do: @pattern

  @impl true
  def run(%SourceFile{} = source_file, params) do
    # Almost every file contains the prefix nowhere at all, and ruling one out on the raw binary is
    # ~17x cheaper than pulling its lines out of Credo's ETS cache to scan them one by one.
    if :binary.match(SourceFile.source(source_file), @prefix) == :nomatch,
      do: [],
      else: scan(source_file, IssueMeta.for(source_file, params))
  end

  defp scan(source_file, issue_meta) do
    source_file
    |> SourceFile.lines()
    |> Enum.flat_map(fn {line_no, line} ->
      @pattern
      |> Regex.scan(line)
      |> Enum.map(fn [match] -> issue_for(issue_meta, line_no, match) end)
    end)
  end

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(issue_meta,
      message: "Bean id in the tree — write out what it stands for, or drop it.",
      line_no: line_no,
      trigger: trigger
    )
  end
end
