defmodule IthibatiOpen.BundlingTest do
  @moduledoc """
  The one claim about Ithibati that only a bundler can answer.

  The library's README tells a consumer to write `import {hooks} from "ithibati"`, a bare specifier
  with no build configuration — which works because the published package carries a `package.json`
  whose `exports` points at `priv/static/ithibati.js`, and because a Phoenix application already has
  `deps` on esbuild's `NODE_PATH`. Nothing else here proves it: `Ithibati.PackageTest` proves the
  file is *shipped*, and this example resolves the same import through an `--alias` instead, because
  a path dependency gets no `deps/ithibati` for the real mechanism to find.

  So the consumer's layout is built here and handed to a real esbuild. It lives in this example
  rather than in the library because this is where a bundler is; it lives in only one of the two
  examples because it is a claim about the library, not about either of them.
  """
  use ExUnit.Case, async: true

  # Asked of Mix rather than counted in `..`s, so that moving this file cannot quietly point it at
  # the wrong tree.
  @library Mix.Project.deps_paths()[:ithibati]

  # The import the README documents, under the name a reader would pick for themselves.
  @entry ~s|import {hooks} from "ithibati"\nexport default hooks\n|

  # Outside the repository, and that is load-bearing rather than tidy: ExUnit's `@tag :tmp_dir` puts
  # its directory under the project, which is *inside* the `ithibati` package — and a file inside a
  # package may import that package by its own name. Measured: esbuild then resolves `"ithibati"`
  # through the repository's own `package.json`, five directories up, and the negative test below
  # can never fail. The pid is in the name because two checkouts running at once draw their unique
  # integers from different virtual machines.
  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "ithibati-bundling-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    # Installed by `mix assets.setup`, which the gate runs before the tests — but a bare `mix test`
    # in a fresh checkout does not, and `System.cmd/3` on a missing binary raises a bare `:enoent`
    # that names nothing.
    unless File.exists?(Esbuild.bin_path()) do
      flunk("esbuild is not installed in this build — run `mix assets.setup` first")
    end

    package = Path.join([root, "deps", "ithibati"])

    File.mkdir_p!(Path.join([package, "priv", "static"]))
    File.mkdir_p!(Path.join(root, "assets"))

    File.cp!(Path.join(@library, "package.json"), Path.join(package, "package.json"))

    File.cp!(
      Path.join([@library, "priv", "static", "ithibati.js"]),
      Path.join([package, "priv", "static", "ithibati.js"])
    )

    File.write!(Path.join([root, "assets", "app.js"]), @entry)

    %{root: root, package: package, out: Path.join(root, "bundle.js")}
  end

  defp bundle(%{root: root, out: out}) do
    System.cmd(
      Esbuild.bin_path(),
      ["app.js", "--bundle", "--format=esm", "--outfile=#{out}"],
      cd: Path.join(root, "assets"),
      env: [{"NODE_PATH", Path.join(root, "deps")}],
      stderr_to_stdout: true
    )
  end

  test "a consumer's bare import resolves to the library's JavaScript", context do
    assert {output, 0} = bundle(context)

    # Resolved *and* the right file: an empty module would also have exited 0.
    assert File.read!(context.out) =~ "Ithibati.Web.Hooks.PasskeyCeremony"

    # The banner esbuild prints, not the count it prints beneath it: the summary wording is the half
    # that can change without anybody noticing this stopped matching.
    refute output =~ ~r/\[WARNING\]/
  end

  # The other half, and the reason this test is worth its length: without the file the failure is a
  # consumer's bundler refusing to build, which nothing in this repository would otherwise notice.
  test "and does not resolve without the package.json that makes it possible", context do
    File.rm!(Path.join(context.package, "package.json"))

    {output, exit_code} = bundle(context)

    assert exit_code != 0
    assert output =~ ~s|Could not resolve "ithibati"|
  end
end
