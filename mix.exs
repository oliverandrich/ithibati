defmodule Ithibati.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/oliverandrich/ithibati"

  # The README opens with this text, and hex.pm shows it. `Ithibati.PackageTest` holds the two
  # together: they had already drifted once, with hex.pm still advertising tokens after the
  # library had stopped issuing any.
  @description "Passkey authentication for Elixir applications: accounts, WebAuthn credentials, " <>
                 "recovery codes and revocable sessions. It has no opinion about what an account " <>
                 "may do. The web half is optional and built for Phoenix."

  def project do
    [
      app: :ithibati,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: compilers(),
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

  # The LiveView compiler is what writes the manifest a consumer imports as
  # `phoenix-colocated/ithibati`, and it writes one per application, for the current one alone — so
  # a consumer's own compiler does not write ours. It cannot be listed unconditionally: an
  # application that took this library without Phoenix never receives `phoenix_live_view`, and its
  # build would die on `The task "compile.phoenix_live_view" could not be found`.
  #
  # The condition is an environment variable because nothing else is visible from here. A
  # dependency's `project/0` can read the process environment and nothing about the project being
  # built — measured: `Code.ensure_loaded?` is false even in a consumer where the task exists, and
  # `deps_path()`/`build_path()` answer with directories under this library that do not exist. A
  # consumer who does not set it imports `priv/static/ithibati.js` by path instead, which is the
  # route that always works.
  defp compilers do
    if enabled?("ITHIBATI_COLOCATED_HOOKS"),
      do: [:phoenix_live_view] ++ Mix.compilers(),
      else: Mix.compilers()
  end

  defp card_on_the_redirect(_args) do
    path = Path.join(Mix.Project.config()[:docs][:output] || "doc", "index.html")

    File.write!(path, with_card(File.read!(path)))
  end

  # Escaped rather than forbidden. The alternative was a test refusing `&` in `@description`,
  # which is also the hex.pm blurb and the README's opening paragraph — so an ampersand in
  # ordinary prose would have failed the suite for a reason belonging to an HTML attribute.
  # Four characters is the whole of it for a double-quoted attribute, and `&` goes first.
  @doc false
  def escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  @doc false
  def with_card(html) do
    cond do
      # `mix docs` can run twice over a build it did not rewrite from scratch.
      html =~ "og:image" ->
        html

      String.contains?(html, "</head>") ->
        String.replace(html, "</head>", social_card(:html) <> "</head>")

      # `String.replace/3` with no match answers the string it was given, so without this the
      # patch would quietly do nothing the day ExDoc changes that template.
      true ->
        Mix.raise("ExDoc's redirect page has no </head> to put the card before")
    end
  end

  defp refuse_partial_package(_args) do
    if enabled?("ITHIBATI_WITHOUT_OPTIONAL") do
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
      # `optional:` rather than `only: [:dev, :test]`, because the checks under
      # `lib/ithibati/credo/` are for consumers and an `only:` dependency never reaches one:
      # measured in a throwaway consumer, the guard is then false when this library compiles in
      # their tree and the checks silently do not exist. Not moved into `optional_deps/0` — the
      # tests under `test/credo/` need it, and the absent case is proven where it matters, in a
      # consumer's own `MIX_ENV=prod` build.
      {:credo, "~> 1.7", optional: true, runtime: false},
      {:ex_slop, "~> 0.4.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # HEEX in the guides is otherwise rendered unhighlighted beside the Elixir around it.
      {:makeup_eex, "~> 2.0", only: :dev, runtime: false},
      {:makeup_html, "~> 0.2", only: :dev, runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ] ++ optional_deps()
  end

  # Optional so that a consumer who only wants the context does not pull Phoenix in behind it.
  # `mix deps.get` fetches optional dependencies for *this* project's own build, though, so a
  # normal run always compiles with them present and the path a consumer without them takes is
  # never compiled at all — while `precommit` runs `--warnings-as-errors`. Leaving them out of the
  # list is the only way to compile that path, so one CI leg sets this and nothing else does.
  defp optional_deps do
    if enabled?("ITHIBATI_WITHOUT_OPTIONAL") do
      []
    else
      [
        # Not `~> 1.7`/`~> 1.0`, below which `Phoenix.LiveView.ColocatedHook` does not exist.
        # `Ithibati.Web.Hooks` compiles for anyone who has Phoenix LiveView at all — that is where
        # `Phoenix.Component` lives, and the environment variable gates the manifest, not the module
        # — so an older pair would fail inside this dependency for a consumer who never asked for a
        # colocated hook. The floor is what the feature needs, said once, rather than a runtime
        # check that reports the same thing later and worse.
        {:phoenix, "~> 1.8", optional: true},
        {:phoenix_live_view, "~> 1.1", optional: true},
        {:plug, "~> 1.16", optional: true}
      ]
    end
  end

  # One reading for both build switches. A named value rather than "anything non-empty", because
  # `ITHIBATI_COLOCATED_HOOKS` is documented in `docs/ceremonies.md`: a consumer who writes `=0`
  # to turn it off means it, and the loose test would have turned it on. An unrecognised value raises rather than
  # falling back, for the reason config/config.exs gives about the other variable it reads — a typo
  # would otherwise make a CI leg an exact copy of another one, green and saying nothing.
  defp enabled?(variable) do
    case System.get_env(variable) do
      value when value in [nil, ""] ->
        false

      value when value in ~w(1 true yes) ->
        true

      value when value in ~w(0 false no) ->
        false

      other ->
        Mix.raise("#{variable} must be one of 1/true/yes/0/false/no, got: #{inspect(other)}")
    end
  end

  # Hex's default list is *replaced*, not extended, so anything new that has to ship — `priv`, a
  # migration template — has to be named here as well as written. `Ithibati.PackageTest` fails when
  # a directory exists on disk and is missing from this list, because the alternative is a package
  # that is short a file while every local test passes.
  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/ithibati/changelog.html"
      },
      files:
        ~w(lib priv docs assets .formatter.exs mix.exs package.json README.md LICENSE CHANGELOG.md)
    ]
  end

  # The pages of the site, in the order they are read. One list rather than two: ExDoc orders the
  # extras by their group, so naming each page again under `extras:` would add nothing but the
  # chance of listing one in a group it is not in — which renders as a page under no group at all,
  # without erroring.
  @guides ~w(docs/overview.md docs/getting_started.md docs/configuration.md docs/ceremonies.md docs/passkeys.md
             docs/invitations.md docs/recovery.md)
  @tooling ~w(docs/doctor.md docs/credo.md)
  @about ["CHANGELOG.md", "LICENSE"]

  # hexdocs redirects `hexdocs.pm/ithibati/…` to this subdomain with a 301, and a scraper
  # fetching a card image is not reliably a thing that follows redirects. Measured, not assumed:
  # `curl -I` on the short form answers 301 and only the long one answers the image.
  #
  # Version-pinned, because hexdocs keeps every version's tree forever while the unversioned
  # path follows the latest release. Without the version, a page frozen at 0.1.0 advertises an
  # image a later release owns, and renaming that file breaks the card on every old page at
  # once, silently, with no build failing anywhere.
  @card_image "https://ithibati.hexdocs.pm/#{@version}/assets/logo.png"

  # ExDoc 0.40 emits no OpenGraph tags of its own and names this hook as the place to add meta
  # tags. Deliberately no `og:title`: without one a scraper falls back to `<title>`, which ExDoc
  # already writes per page, so a link to one guide does not present itself as a link to the
  # whole site.
  @doc false
  def social_card(:html) do
    """
    <meta property="og:type" content="website">
    <meta property="og:site_name" content="Ithibati">
    <meta property="og:description" content="#{escape(@description)}">
    <meta property="og:image" content="#{@card_image}">
    <meta property="og:image:alt" content="The Ithibati logo">
    <meta property="og:image:width" content="1200">
    <meta property="og:image:height" content="675">
    <meta name="twitter:card" content="summary_large_image">
    """
  end

  def social_card(_epub), do: ""

  defp docs do
    [
      # Not the README, on either count. It is the repository's front page: it opens by making the
      # case for the library, which a reader who has arrived here has already heard, and its
      # quickstart is what `docs/getting_started.md` writes out in full.
      main: "overview",
      source_ref: "v#{@version}",
      # Copied into the build under the same name the pages reference, so `assets/logo.png`
      # resolves both on GitHub, which reads the repository, and on hexdocs, which reads this.
      assets: %{"assets" => "assets"},
      before_closing_head_tag: &social_card/1,
      extra_section: "GUIDES",
      extras: @guides ++ @tooling ++ ["CHANGELOG.md", {"LICENSE", title: "Licence"}],
      groups_for_extras: [Guides: @guides, Tooling: @tooling, About: @about],
      # Grouped by who calls them, which is the question a reader arrives with — the flat list put
      # `Ithibati.Catalogue` beside `Ithibati.Identity.Passkeys` and said nothing about which is
      # the API and which is plumbing.
      groups_for_modules: [
        Identity: [~r/^Ithibati\.Identity\./],
        Schemas: [~r/^Ithibati\.Schema\./],
        # `Ithibati.Ceremony` is not under `Web`, because the identity half produces most of the
        # vocabulary and answers without Phoenix. It is read here, where a page turns a code into
        # a sentence.
        Phoenix: [~r/^Ithibati\.Web\./, Ithibati.Ceremony],
        "Rows this library owns": [
          Ithibati.Bootstrap,
          Ithibati.RecoveryCode,
          Ithibati.Session,
          Ithibati.UserKey
        ],
        "Setup and tooling": [
          Ithibati.Catalogue,
          Ithibati.Config,
          Ithibati.Doctor,
          Ithibati.Migration,
          Mix.Tasks.Ithibati.Doctor
        ],
        "Credo checks": [~r/^Ithibati\.Credo\./]
      ]
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
      # ExDoc writes `index.html` from a redirect template of its own, and that template has no
      # head hook — so the one URL anybody actually shares, the documentation root, is a
      # meta-refresh carrying no card. A scraper does not follow a meta-refresh. Patched after
      # the build rather than left alone. `mix hex.publish` reaches `docs` through
      # `Mix.Task.run/2`, which resolves aliases, so the published copy is patched too.
      docs: ["docs", &card_on_the_redirect/1],
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
