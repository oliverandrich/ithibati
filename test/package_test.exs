defmodule Ithibati.PackageTest do
  use ExUnit.Case, async: true

  # Hex replaces its default file list with `package(files:)` rather than extending it, so a
  # directory added to the repository does not reach the published package until somebody also
  # names it in mix.exs. Nothing local fails when they forget: every test reads the working tree,
  # where the file is present. The first consumer finds out instead.
  @shippable ~w(lib priv src docs)

  # Files rather than directories, and named one by one: a directory is shippable because of what it
  # is, a loose file because of what it does. `package.json` is what makes `import … from "ithibati"`
  # resolve, and a package without it fails in a consumer's bundler rather than in any test here.
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
end
