defmodule Ithibati.PackageTest do
  use ExUnit.Case, async: true

  # Hex replaces its default file list with `package(files:)` rather than extending it, so a
  # directory added to the repository does not reach the published package until somebody also
  # names it in mix.exs. Nothing local fails when they forget: every test reads the working tree,
  # where the file is present. The first consumer finds out instead.
  @shippable ~w(lib priv src docs)

  test "every shippable directory that exists is in the package file list" do
    files = Mix.Project.config()[:package][:files]

    for dir <- @shippable, File.dir?(dir) do
      assert dir in files,
             "#{dir}/ exists but is missing from package(files:) in mix.exs — it would be absent " <>
               "from the published package"
    end
  end
end
