defmodule Ithibati.PackageTest do
  use ExUnit.Case, async: true

  # Hex replaces its default file list with `package(files:)` rather than extending it, so a
  # directory added to the repository does not reach the published package until somebody also
  # names it in mix.exs. Nothing local fails when they forget: every test reads the working tree,
  # where the file is present. The first consumer finds out instead.
  @shippable ~w(lib priv src docs)

  # Files rather than directories, and named one by one: a directory is shippable because of what it
  # is, a loose file because of what it does. `package.json` is what makes `import … from "ithibati"`
  # resolve; that it *does* resolve is proven against a real bundler in
  # `examples/open_registration/test/ithibati_open/bundling_test.exs`, and this is the half that
  # makes sure it reaches the consumer at all.
  @shippable_files ~w(package.json)

  test "every shippable directory that exists is in the package file list" do
    files = Mix.Project.config()[:package][:files]

    for dir <- @shippable, File.dir?(dir) do
      assert dir in files,
             "#{dir}/ exists but is missing from package(files:) in mix.exs — it would be absent " <>
               "from the published package"
    end
  end

  test "every shippable loose file that exists is in the package file list" do
    files = Mix.Project.config()[:package][:files]

    for file <- @shippable_files, File.regular?(file) do
      assert file in files,
             "#{file} exists but is missing from package(files:) in mix.exs — it would be absent " <>
               "from the published package"
    end
  end

  # The two had drifted, and nothing said so: hex.pm was still advertising revocable tokens after
  # the library had stopped issuing any. The README's opening paragraph is the description, so a
  # rewrite of one has to reach the other.
  test "the package description is the paragraph the README opens with" do
    # The *first* paragraph that is prose, found by position rather than by its opening words. A
    # search for the words would be a third copy of the text these two are being held to, and it
    # would stay green for a README whose opening paragraph had moved to the bottom.
    opening =
      "README.md"
      |> File.read!()
      |> String.split(~r/\n\s*\n/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.find(&(not String.starts_with?(&1, ["#", "![", "[", ">"])))

    refute is_nil(opening), "README.md has no prose paragraph for the description to match"

    assert normalise(opening) == normalise(Mix.Project.config()[:description])
  end

  # Line breaks are the author's business, and a hard break at the end of a line is invisible.
  defp normalise(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end
