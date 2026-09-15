# SPDX-License-Identifier: MIT

defmodule Ithibati.Credo.IdentityIsPortable do
  use Credo.Check,
    id: "ITH001",
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Two rules about what the core of this library may depend on, at the two different reaches they
      actually have.

      `Ithibati.Identity` is the module that knows who someone is and how they prove it — the
      account row, passkeys, recovery codes, tokens. It may name only the few modules listed as its
      own, so that a consuming application's ideas about roles and tenancy cannot creep into it.
      What it reports is an `Ithibati.` sibling outside that list: an identity function reaching
      into `Ithibati.Content` to rewrite an author's posts, say. A name rooted anywhere else is
      left to review, because a consumer's own contexts are not this check's to judge.

      Separately, and for every core module rather than that one: `phoenix`, `phoenix_live_view`
      and `plug` are optional dependencies, so a consumer who does not want them must still get a
      core that compiles. Nothing under `lib/` outside the web half may name one.

      If the new code genuinely needs the other thing, it belongs above this — in the web half, or
      in the consuming application.
      """
    ]

  # After the `use` and not before it, which is the whole trick: `Credo.Check` writes a moduledoc
  # from its `explanations:` block, so an attribute set first is overwritten and one set afterwards
  # wins. Hidden because this check guards this repository and is not in the package — `mix docs`
  # runs in `dev`, where `elixirc_paths` includes `credo/`, so without this it gets a page on
  # hexdocs describing a rule nobody reading it can switch on.
  @moduledoc false

  alias Credo.Code.Name

  # Allowed rather than forbidden: a module added next year is refused without anyone remembering
  # this file exists, which forces a conscious decision instead of a silent one. `Identity` is on the
  # list because the guarded module's own `defmodule` line is an alias node too.
  @allowed [:Bootstrap, :Config, :Identity, :RecoveryCode, :Session, :UserKey]

  @optional_deps [:Phoenix, :Plug]

  @web_root "lib/ithibati/web/"

  # Matched in the AST rather than against a filename. A path has to be kept equal to where the
  # module actually is, by hand and by a test; `defmodule` cannot drift from the module it declares.
  #
  # A prefix, not one name: the portable half is `Ithibati.Identity.Passkeys`,
  # `Ithibati.Identity.Sessions` and whatever joins them, and a list of exact names would leave the
  # next one unguarded until somebody remembered this file — which is the failure that is silent and
  # points the wrong way. `Ithibati.Identity` itself is covered in case it ever exists again.
  @guarded [:Ithibati, :Identity]

  @impl true
  def run(%SourceFile{filename: filename} = source_file, params) do
    if core?(filename),
      do: scan(source_file, IssueMeta.for(source_file, params)),
      else: []
  end

  # Scoped here rather than through `param_defaults: [files: …]`, which Credo would apply for us:
  # that filter runs before the check and so cannot be reached from a unit test, and which files
  # count as core is the load-bearing half of the optional-dependency rule.
  defp core?(filename) do
    path = Path.relative_to_cwd(filename)
    String.starts_with?(path, "lib/") and not String.starts_with?(path, @web_root)
  end

  defp scan(source_file, issue_meta) do
    ast = SourceFile.ast(source_file)
    guarded? = declares_guarded?(ast)

    ast
    |> Credo.Code.prewalk(fn node, acc -> {node, collect(node, acc, issue_meta, guarded?)} end)
    |> Enum.reverse()
  end

  defp declares_guarded?({:defmodule, _meta, [{:__aliases__, _, segments} | _rest]}),
    do: List.starts_with?(segments, @guarded)

  defp declares_guarded?({:__block__, _meta, nodes}), do: Enum.any?(nodes, &declares_guarded?/1)
  defp declares_guarded?(_node), do: false

  defp collect({:__aliases__, meta, segments}, acc, issue_meta, guarded?) do
    case refuse(segments, guarded?) do
      nil -> acc
      refusal -> [issue_for(issue_meta, meta[:line], refusal) | acc]
    end
  end

  # `alias Ithibati.{Config, UserKey}` does not nest: `Ithibati` stands alone and each name is its
  # own node with no prefix, so the clause above cannot see it. No such clause is needed for the
  # optional dependencies — a bare `Phoenix` node is refused on its own, where a bare `Ithibati` one
  # is not.
  defp collect(
         {{:., _dot, [{:__aliases__, _, [:Ithibati]}, :{}]}, meta, parts},
         acc,
         im,
         guarded?
       ) do
    parts
    |> Enum.flat_map(&refused_part(&1, guarded?))
    |> Enum.reduce(acc, &[issue_for(im, meta[:line], &1) | &2])
  end

  defp collect(_node, acc, _issue_meta, _guarded?), do: acc

  # Not every element of a `{…}` is an alias node — `alias Ithibati.{unquote(mod)}` puts a call
  # there, and a raise inside a check aborts the whole Credo run rather than reporting anything.
  defp refused_part({:__aliases__, _meta, segments}, guarded?),
    do: List.wrap(refuse([:Ithibati | segments], guarded?))

  defp refused_part(_other, _guarded?), do: []

  # `Elixir.Phoenix.PubSub` is the same reference written out; the compiler strips the prefix and so
  # does this.
  defp refuse([:"Elixir" | rest], guarded?), do: refuse(rest, guarded?)

  defp refuse([root | _rest] = segments, _guarded?) when root in @optional_deps,
    do: {:optional_dep, segments |> Enum.take(2) |> Name.full()}

  # Clauses rather than an entry on the list above, which matches the second segment alone and would
  # have admitted every `Ithibati.Schema.*` there will ever be. Both named modules are this library's
  # own contract with a schema the application owns, not another context: the ceremony asks `User`
  # what belongs in a credential, and `Identifier` for the one normalisation an identifier gets, so
  # that a lookup cannot disagree with the write that stored it.
  defp refuse([:Ithibati, :Schema, :User], true), do: nil
  defp refuse([:Ithibati, :Schema, :Identifier], true), do: nil

  defp refuse([:Ithibati, sibling | _rest], true) when sibling not in @allowed,
    do: {:not_allowed, Name.full([:Ithibati, sibling])}

  defp refuse(_segments, _guarded?), do: nil

  defp issue_for(issue_meta, line_no, {rule, trigger}),
    do: format_issue(issue_meta, message: message(rule), line_no: line_no, trigger: trigger)

  defp message(:not_allowed),
    do: "The portable half may not name this — it belongs above, in the web half or the app."

  defp message(:optional_dep),
    do: "The core must compile without the optional dependencies — this belongs in the web half."
end
