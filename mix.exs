defmodule Ithibati.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/oliverandrich/ithibati"

  # One copy, because README.md opens with it verbatim and hex.pm shows it.
  @description "Passkey authentication for Elixir applications — accounts, WebAuthn credentials, " <>
                 "recovery codes and revocable tokens — without an opinion about what an account " <>
                 "may do. The optional web half is for Phoenix."

  def project do
    [
      app: :ithibati,
      version: @version,
      # The floor is this library's own: `Ithibati.Identity` builds its expiry cutoff with
      # `DateTime.shift/2`, which arrived in 1.17. Every shipped dependency sits lower (`ecto_sql`
      # and `postgrex` at `~> 1.15`); `yaml_elixir`, which reaches the build through `mix_audit` in
      # dev and test only, sits exactly here and would be the first thing to push this up for a
      # reason that has nothing to do with the library. CI builds both ends of the range, so the
      # requirement is measured rather than hoped for.
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "Ithibati",
      description: @description,
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  # Both end in `mix test`, which refuses to run outside the test environment — and without this
  # `build_and_test` would compile the whole tree once in `dev` and then again in `test`.
  def cli do
    [preferred_envs: [precommit: :test, build_and_test: :test]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # `credo` holds this project's own checks: dev and test only, because they guard this repository
  # rather than shipping to anyone.
  defp elixirc_paths(:test), do: ["lib", "test/support", "credo"]
  defp elixirc_paths(:dev), do: ["lib", "credo"]
  defp elixirc_paths(_), do: ["lib"]

  defp refuse_partial_package(_args) do
    if System.get_env("ITHIBATI_WITHOUT_OPTIONAL") not in [nil, ""] do
      Mix.raise(
        "ITHIBATI_WITHOUT_OPTIONAL is set, which drops the optional dependencies from deps/0. " <>
          "A package built now would not declare them. Unset it and try again."
      )
    end
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.12"},
      {:wax_, "~> 0.7"},
      {:postgrex, "~> 0.19", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ] ++ optional_deps()
  end

  # Optional so that a consumer who only wants the context does not pull Phoenix in behind it.
  # `mix deps.get` fetches optional dependencies for *this* project's own build, though, so a
  # normal run always compiles with them present and the path a consumer without them takes is
  # never compiled at all — while `precommit` runs `--warnings-as-errors`. Leaving them out of the
  # list is the only way to compile that path, so one CI leg sets this and nothing else does.
  defp optional_deps do
    if System.get_env("ITHIBATI_WITHOUT_OPTIONAL") in [nil, ""] do
      [
        {:phoenix, "~> 1.7", optional: true},
        {:phoenix_live_view, "~> 1.0", optional: true},
        {:plug, "~> 1.16", optional: true}
      ]
    else
      []
    end
  end

  # Hex's default list is *replaced*, not extended, so anything new that has to ship — `priv`, a
  # migration template — has to be named here as well as written. `Ithibati.PackageTest` fails when
  # a directory exists on disk and is missing from this list, because the alternative is a package
  # that is short a file while every local test passes.
  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib docs .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "docs/design.md", "CHANGELOG.md", "LICENSE"]
    ]
  end

  defp aliases do
    [
      # `optional_deps/0` reads the environment, and `deps/0` is what `mix hex.publish` reads to
      # write a package's metadata — so a variable left over from reproducing a CI leg would publish
      # a release that does not declare its optional dependencies at all. Checked here rather than
      # in `project/0`, which every mix task evaluates, including the leg that sets it.
      "hex.build": [&refuse_partial_package/1, "hex.build"],
      "hex.publish": [&refuse_partial_package/1, "hex.publish"],
      # Split where CI needs to cut it: a leg that asks whether this builds and behaves on another
      # Elixir runs `build_and_test` and nothing about style, because a formatter or Credo release
      # judges the tree against the toolchain it was written with. Composed rather than listed
      # twice, so a step added here cannot quietly skip that leg.
      style: ["format --check-formatted", "deps.unlock --check-unused", "credo --strict"],
      build_and_test: ["compile --warnings-as-errors", "test"],
      precommit: ["style", "build_and_test"]
    ]
  end
end
