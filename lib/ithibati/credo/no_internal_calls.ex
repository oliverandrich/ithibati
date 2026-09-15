# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Credo.Check) do
  defmodule Ithibati.Credo.NoInternalCalls do
    alias Ithibati.Credo.Aliases

    use Credo.Check,
      id: "ITH103",
      base_priority: :high,
      category: :warning,
      explanations: [
        check: """
        Some of Ithibati's functions are public only so that Ithibati can assemble its own flows
        across modules. Elixir has no way to say that: `defp` does not reach across a module, and
        nothing in the language hides a function from a caller. So Ithibati marks those functions
        `@doc false`, or puts them in a module marked `@moduledoc false`, and this check reports
        a call to one.

        What is marked is not a matter of taste. It is what Ithibati will change without telling
        you, because a release that is careful about its public surface is careless about the
        rest.

        If something you need is only reachable past that line, say so rather than reaching for
        it. The gap is in Ithibati, and a function somebody depends on is one worth documenting.

        The list is not kept here. The check reads it from the compiled modules, so it is
        whatever the code says today and cannot drift from it.
        """
      ]

    @impl true
    def run(%SourceFile{} = source_file, params) do
      ast = SourceFile.ast(source_file)
      aliases = Aliases.collect(ast)

      ast
      |> Credo.Code.prewalk(&candidates(&1, &2, aliases))
      |> published_arities()
      |> Enum.reverse()
      |> Enum.map(&issue_for(IssueMeta.for(source_file, params), &1))
    end

    # Gathered first and judged afterwards, so the documentation chunk of each module is read once
    # however many times that module is called.
    defp published_arities(candidates) do
      known =
        candidates
        |> Enum.map(fn {module, _fun, _arity, _line} -> module end)
        |> Enum.uniq()
        |> Map.new(&{&1, docs(&1)})

      for {module, fun, arity, line} <- candidates,
          published = published_arity(Map.fetch!(known, module), fun, arity),
          do: {module, fun, published, line}
    end

    # A pipe is the call it stands for, with one more argument than the node carries — and the
    # arity is what the documentation is looked up by.
    defp candidates({:|>, _meta, [lhs, {{:., dot, [module, fun]}, call, args}]}, acc, aliases) do
      node = {{:., dot, [module, fun]}, call, [lhs | args]}
      {_rewritten, acc} = candidates(node, acc, aliases)
      {node, acc}
    end

    # `&Module.fun/2` carries its arity as a literal and no arguments at all.
    defp candidates(
           {:&, meta, [{:/, _, [{{:., _, [{:__aliases__, _, segments}, fun]}, _, []}, arity]}]} =
             node,
           acc,
           aliases
         )
         when is_atom(fun) and is_integer(arity),
         do: {node, record(segments, fun, arity, meta[:line], acc, aliases)}

    defp candidates(
           {{:., _, [{:__aliases__, _, segments}, fun]}, meta, args} = node,
           acc,
           aliases
         )
         when is_atom(fun) and is_list(args),
         do: {node, record(segments, fun, length(args), meta[:line], acc, aliases)}

    defp candidates(node, acc, _aliases), do: {node, acc}

    defp record(segments, fun, arity, line, acc, aliases) do
      case Aliases.resolve(segments, aliases) do
        nil -> acc
        module -> [{module, fun, arity, line} | acc]
      end
    end

    # What a consumer legitimately calls on one of this library's modules, whoever wrote it:
    # reflection a `use` put there. Named by what may be called rather than by who generated it,
    # because the two are not the same question — `__changeset__/0` is Ecto's and fair game, while
    # `__changeset__/5` is this library's own and marked by hand.
    @reflection [
      {:__schema__, 1},
      {:__schema__, 2},
      {:__struct__, 0},
      {:__struct__, 1},
      {:__changeset__, 0},
      {:__info__, 1}
    ]

    # The arity the function is published under, or `nil`, which is also what says "not hidden".
    # A call may be written at a lower arity, and naming that one would name a function the
    # library does not have.
    defp published_arity(_docs, fun, arity) when {fun, arity} in @reflection, do: nil

    defp published_arity(:hidden_module, _fun, arity), do: arity

    defp published_arity(docs, fun, arity) when is_list(docs) do
      Enum.find_value(docs, fn
        {{kind, ^fun, published}, _, _, :hidden, meta} when kind in [:function, :macro] ->
          # A default argument is published once, at the highest arity, with a count of how many
          # may be left out — so a call at any of the lower arities is the same function.
          arity in (published - Map.get(meta, :defaults, 0))..published and published

        _other ->
          nil
      end)
    end

    defp published_arity(_other, _fun, _arity), do: nil

    # A module whose documentation chunk was stripped answers nothing, and this check then reports
    # nothing about it — which reads exactly like a clean run. Said out loud in `docs/credo.md`
    # rather than guessed at here, because a rule that invented an issue out of a missing chunk
    # would be worse.
    defp docs(module) do
      case Code.fetch_docs(module) do
        {:docs_v1, _, _, _, :hidden, _, _} -> :hidden_module
        {:docs_v1, _, _, _, _, _, docs} -> docs
        _error -> :unknown
      end
    end

    defp issue_for(issue_meta, {module, fun, arity, line}) do
      format_issue(issue_meta,
        message:
          "#{inspect(module)}.#{fun}/#{arity} is internal to this library — it is not documented, " <>
            "and it changes without notice.",
        line_no: line,
        trigger: "#{fun}"
      )
    end
  end
end
