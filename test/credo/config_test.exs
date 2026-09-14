defmodule Ithibati.Credo.ConfigTest do
  @moduledoc """
  Credo prints `Ignoring an undefined check` for a name it cannot resolve and exits zero anyway, so a
  check renamed, moved off `elixirc_paths` or misspelled in `.credo.exs` stops running without
  turning anything red — the gate keeps saying "no issues" about a file nobody looks at.

  Note what this cannot cover: `mix credo` requires only `loadpaths`, not `compile`, so a bare
  `mix credo` against stale build artifacts silently runs without these checks. `mix precommit`
  compiles first, which is why the gate is sound and a hand-run `mix credo` is not.
  """
  use ExUnit.Case, async: true

  setup_all do
    {config, _bindings} = Code.eval_file(".credo.exs")

    %{
      configured: for({mod, _opts} <- extra(config[:configs]), do: mod),
      # Read out of the tree rather than restated: a third check added under `credo/` and forgotten
      # in `.credo.exs` has to turn this red, and a hardcoded list is exactly what cannot. From the
      # sources rather than from the application manifest, which goes stale and keeps listing
      # modules whose beam is gone.
      shipped: Enum.flat_map(Path.wildcard("credo/**/*.ex"), &modules_in/1),
      offered: Enum.flat_map(Path.wildcard("lib/ithibati/credo/**/*.ex"), &modules_in/1)
    }
  end

  defp extra(configs), do: Enum.flat_map(configs, &get_in(&1, [:checks, :extra]))

  # Through the parser rather than a regex: a check that ships is wrapped in
  # `if Code.ensure_loaded?(...)`, so its `defmodule` is indented, and a pattern loose enough for
  # that also matches the example inside an explanation heredoc — a check documenting the better
  # way to write something would then invent a module and demand a test for it.
  defp modules_in(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {:defmodule, _meta, [{:__aliases__, _, segments} | _rest]} = node, acc ->
        {node, [Module.concat(segments) | acc]}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  test "every check under credo/ is named in .credo.exs", %{
    configured: configured,
    shipped: shipped
  } do
    refute shipped == [], "no checks found under credo/ — this test would pass vacuously"

    for check <- shipped do
      assert check in configured, "#{inspect(check)} exists but .credo.exs never names it"
    end
  end

  # The mirror image, and it is a decision rather than an omission. The checks under
  # `lib/ithibati/credo/` are offered to consumers, and they do not scope by filename — so run
  # against this tree they would report `Ithibati.Identity`, which reaches those tables because
  # that is its job. Registering one here would be a gate that refuses the library for doing what
  # the library is for.
  test "no check offered to consumers is switched on for this repository", %{
    configured: configured,
    offered: offered
  } do
    refute offered == [], "no consumer checks found under lib/ithibati/credo/"

    for check <- offered do
      refute check in configured,
             "#{inspect(check)} ships to consumers and must not run against this tree"
    end
  end

  # Their guard is their tests, since `.credo.exs` is not allowed to be one.
  test "every check offered to consumers has a test of its own", %{offered: offered} do
    for check <- offered do
      path =
        check
        |> Module.split()
        |> List.last()
        |> Macro.underscore()
        |> then(&"test/credo/#{&1}_test.exs")

      assert File.exists?(path), "#{inspect(check)} has no test at #{path}"
    end
  end

  # `Credo.Check.defined?/1` is the predicate whose failure prints the warning this module exists
  # for, so it is the one worth asserting rather than a lookalike of it.
  test "every check named in .credo.exs is one Credo would accept", %{configured: configured} do
    refute configured == []

    for check <- configured do
      assert Credo.Check.defined?(check),
             "#{inspect(check)} is in .credo.exs but Credo cannot use it"
    end
  end
end
