# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Credo.Check) do
  defmodule Ithibati.Credo.Aliases do
    @moduledoc false
    # What a name in somebody else's file refers to, for the checks that have to know whether a
    # call is ours. Shared because all of them need the same answer and the AST knowledge is
    # fiddly enough to be worth having once: the multi-alias form does not nest, `as:` renames,
    # and a name two modules in one file alias differently cannot be answered at all.
    #
    # Not public API despite living in `lib/`. It carries `@moduledoc false`, which is exactly what
    # `Ithibati.Credo.NoInternalCalls` reports a consumer for reaching past.

    @doc """
    Every name this file binds to a module under `Ithibati`, as a map from the bare name.

    Ambiguity is dropped, never guessed at. Two modules in one file can alias the same last
    segment to different things — one to ours, one to their own — and a flat walk has no notion
    of which is in scope where. Losing a finding in a rare file is better than naming a module
    the consumer's source does not contain.
    """
    def collect(ast) do
      ast
      |> Credo.Code.prewalk(&{&1, pairs(&1, &2)})
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn
        {name, [module]} -> if ours?(module), do: [{name, module}], else: []
        {_name, _several} -> []
      end)
      |> Map.new()
    end

    @doc """
    The module a call's alias segments name, or `nil` when it is not one of ours.

    A bare name counts only when this file aliased it from `Ithibati`, and it may be the head of
    a longer call: `alias Ithibati.Identity` makes `Identity.Secrets` ours too.
    """
    def resolve([:"Elixir", :Ithibati | rest], aliases), do: resolve([:Ithibati | rest], aliases)
    def resolve([:Ithibati | _rest] = segments, _aliases), do: Module.concat(segments)

    def resolve([head | rest], aliases) do
      case Map.get(aliases, head) do
        nil -> nil
        module -> Module.concat([module | rest])
      end
    end

    def resolve(_segments, _aliases), do: nil

    defp ours?(module), do: List.starts_with?(Module.split(module), ["Ithibati"])

    defp pairs({:alias, _meta, [{:__aliases__, _, segments}]}, acc),
      do: named(segments, List.last(segments), acc)

    defp pairs({:alias, _meta, [{:__aliases__, _, segments}, opts]}, acc) when is_list(opts) do
      case Keyword.fetch(opts, :as) do
        {:ok, {:__aliases__, _, [name]}} -> named(segments, name, acc)
        _other -> named(segments, List.last(segments), acc)
      end
    end

    # `alias Ithibati.Identity.{Secrets, Sessions}` does not nest: each name is its own node, and
    # the prefix stands alone in front of them.
    defp pairs({{:., _, [{:__aliases__, _, prefix}, :{}]}, _meta, parts}, acc) do
      for {:__aliases__, _, segments} <- parts, reduce: acc do
        pairs -> named(prefix ++ segments, List.last(segments), pairs)
      end
    end

    defp pairs(_node, acc), do: acc

    defp named(segments, name, acc), do: [{name, Module.concat(segments)} | acc]
  end
end
