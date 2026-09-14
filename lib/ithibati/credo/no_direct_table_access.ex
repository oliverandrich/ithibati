# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Credo.Check) do
  defmodule Ithibati.Credo.NoDirectTableAccess do
    alias Ithibati.Credo.Aliases

    use Credo.Check,
      id: "ITH101",
      base_priority: :high,
      category: :warning,
      explanations: [
        check: """
        This library's tables are reached through this library, not queried directly.

        Not a matter of taste. A token row is only meaningful with its context: `Ithibati.Identity`
        matches on it, so a hand-written query against the tokens table accepts a session token
        where a device token was meant. A recovery code is single-use, and that is enforced where
        it is spent, not by the row — a query that reads one directly can spend it twice. The same
        applies to the keys table, where a credential is only valid for the account it was
        enrolled against.

        Read them through `Ithibati.Identity` instead. If something you need is not reachable from
        there, that is worth reporting rather than working around: the gap is in this library.

        Matching on a struct this library handed you — `%Ithibati.UserKey{} = key` — is not this,
        and neither is an `alias`; only using one as the thing being read is.
        """
      ]

    # The schemas, not the table names: the prefix is the application's to choose, so a name
    # written out here would be wrong for anybody who set one.
    @owned [Ithibati.UserKey, Ithibati.RecoveryCode, Ithibati.UserToken, Ithibati.Bootstrap]

    @impl true
    def run(%SourceFile{} = source_file, params) do
      ast = SourceFile.ast(source_file)

      known = %{
        aliased: Aliases.collect(ast),
        prefix: table_prefix(),
        issue_meta: IssueMeta.for(source_file, params)
      }

      ast
      |> Credo.Code.prewalk(&{&1, collect(&1, &2, known)})
      |> Enum.reverse()
    end

    defp collect(node, acc, known) do
      case source_of(node) do
        nil -> acc
        {source, meta} -> reading(source, meta, acc, known)
      end
    end

    # Positions rather than a list of call shapes: a list cannot cover the pipe, the `join:`, or a
    # repo not spelled `Repo`, while a schema *being read* is in one of these places whatever the
    # surrounding call is named. None of them is somewhere a struct literal or an `alias` appears,
    # which is what keeps the rule off ordinary handling. The last is where a table name has to be
    # written out, so it is also the one that catches a schema of one's own over a table of ours.
    defp source_of({:|>, meta, [source | _rest]}), do: {source, meta}
    defp source_of({:in, meta, [_binding, source]}), do: {source, meta}
    defp source_of({{:., _, [_module, _fun]}, meta, [source | _rest]}), do: {source, meta}
    defp source_of({:schema, meta, [source | _rest]}), do: {source, meta}
    defp source_of(_node), do: nil

    defp reading({:__aliases__, _meta, segments}, meta, acc, known) do
      case Aliases.resolve(segments, known.aliased) do
        nil -> acc
        module -> owned(module, segments, meta, acc, known)
      end
    end

    defp reading(table, meta, acc, known) when is_binary(table) do
      if String.starts_with?(table, known.prefix),
        do: [issue_for(known, meta[:line], ~s("#{table}"), table) | acc],
        else: acc
    end

    defp reading(_source, _meta, acc, _known), do: acc

    # Resolved to a module first, so a consumer's own `MyApp.Bootstrap` is not reported as
    # ours with a message naming a module their source does not contain.
    defp owned(module, segments, meta, acc, known) do
      if module in @owned,
        do: [issue_for(known, meta[:line], inspect(module), List.last(segments)) | acc],
        else: acc
    end

    # Read rather than assumed: an application that set a prefix has different table names, and
    # this check runs inside that application, where the setting is there to be read.
    defp table_prefix, do: Application.get_env(:ithibati, :table_prefix, "ithibati") <> "_"

    defp issue_for(known, line_no, name, trigger) do
      format_issue(known.issue_meta,
        message: "#{name} read directly — reach it through Ithibati.Identity.",
        line_no: line_no,
        trigger: "#{trigger}"
      )
    end
  end
end
