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
      # Matches the mise.toml pin; nothing builds this at any other version.
      elixir: "~> 1.20",
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

  # `precommit` ends in `mix test`, which refuses to run outside the test environment.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # `credo` holds this project's own checks: dev and test only, because they guard this repository
  # rather than shipping to anyone.
  defp elixirc_paths(:test), do: ["lib", "test/support", "credo"]
  defp elixirc_paths(:dev), do: ["lib", "credo"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.12"},
      {:wax_, "~> 0.7"},

      # Optional so a consumer that only wants the context does not pull Phoenix in behind it.
      # That the library still compiles *without* them is currently an untested claim — see the
      # tracker.
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:plug, "~> 1.16", optional: true},
      {:postgrex, "~> 0.19", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
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
      precommit: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "deps.unlock --check-unused",
        "credo --strict",
        "test"
      ]
    ]
  end
end
