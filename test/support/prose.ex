defmodule Ithibati.Prose do
  @moduledoc false
  # Which files are prose, derived rather than listed. Three guards ask the question — the bean-id
  # rule, the decision list and the documentation pointers — and a hand-written copy in each is
  # three chances to add a page that two of them then never read.
  #
  # `package(files:)` is the source for what ships, because shipping is what makes a file worth
  # holding to a rule; `CLAUDE.md` is added on top, since it is prose that links into the same
  # documents and is deliberately not in the package.

  @doc "Every file the package ships that is not Elixir source."
  def shipped do
    Mix.Project.config()[:package][:files]
    |> Enum.flat_map(&[&1 | Path.wildcard(&1 <> "/**/*")])
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&(Path.extname(&1) in [".ex", ".exs"]))
  end

  @doc "Every Markdown page a reader is sent to, shipped or not."
  def pages, do: Enum.filter(shipped(), &(Path.extname(&1) == ".md")) ++ ["CLAUDE.md"]
end
