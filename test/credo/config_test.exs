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
      shipped: Enum.flat_map(Path.wildcard("credo/**/*.ex"), &modules_in/1)
    }
  end

  defp extra(configs), do: Enum.flat_map(configs, &get_in(&1, [:checks, :extra]))

  defp modules_in(path) do
    ~r/^defmodule\s+([\w.]+)\s+do/m
    |> Regex.scan(File.read!(path))
    |> Enum.map(fn [_whole, name] -> Module.concat([name]) end)
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
