defmodule Ithibati.Migration.SQLiteRebuild do
  @moduledoc false
  # SQLite cannot change a column's NOT NULL constraint in place. This follows the table rebuild in
  # https://www.sqlite.org/lang_altertable.html#otheralter: create the new table from the stored
  # definition, copy the rows, drop the old table, rename, and recreate its indexes and triggers.
  # The stored definition keeps every column, constraint and foreign key the application wrote.

  @doc """
  Sets whether `column` of `table` accepts NULL. Does nothing when it already does what is asked.
  """
  def nullable(repo, table, column, nullable?) do
    column = to_string(column)
    definition = definition!(repo, table)

    # One connection throughout: `PRAGMA foreign_keys` and `legacy_alter_table` are per connection.
    case rewrite(definition, column, nullable?) do
      :unchanged -> :ok
      {:ok, rewritten} -> repo.checkout(fn -> rebuild(repo, table, rewritten) end)
    end
  end

  defp rebuild(repo, table, rewritten) do
    staging = "ithibati_rebuild_" <> table
    companions = companions(repo, table)

    without_foreign_keys(repo, table, fn ->
      run(repo, "CREATE TABLE #{quote_name(staging)} #{rewritten}")
      run(repo, "INSERT INTO #{quote_name(staging)} SELECT * FROM #{quote_name(table)}")
      run(repo, "DROP TABLE #{quote_name(table)}")
      rename(repo, staging, table)
      Enum.each(companions, &run(repo, &1))

      repo.query!("PRAGMA foreign_key_check(#{quote_name(table)})", [], log: false).rows == [] ||
        raise ArgumentError,
              "rebuilding #{table} left rows whose foreign keys point at nothing; nothing was changed"
    end)
  end

  # Since SQLite 3.26 a rename checks every view and trigger in the schema, and one that names the
  # dropped table fails it. The legacy rename skips that check, as the procedure in the SQLite
  # documentation advises.
  defp rename(repo, staging, table) do
    [[legacy]] = repo.query!("PRAGMA legacy_alter_table", [], log: false).rows
    run(repo, "PRAGMA legacy_alter_table = ON")

    try do
      run(repo, "ALTER TABLE #{quote_name(staging)} RENAME TO #{quote_name(table)}")
    after
      run(repo, "PRAGMA legacy_alter_table = #{legacy}")
    end
  end

  # Dropping the old table deletes its rows first when foreign keys are on, and that fires the
  # ON DELETE actions of every table that references it. SQLite ignores `PRAGMA foreign_keys`
  # inside a transaction, so a referenced table can only be rebuilt outside one.
  defp without_foreign_keys(repo, table, rebuild) do
    if referenced?(repo, table) and foreign_keys?(repo) do
      repo.query!("PRAGMA foreign_keys = OFF", [], log: false)

      foreign_keys?(repo) &&
        raise ArgumentError,
              "other tables reference #{table}, and rebuilding it needs foreign keys off, which " <>
                "SQLite ignores inside a transaction. Add `@disable_ddl_transaction true` to " <>
                "the migration that calls `Ithibati.Migration.open_invitations/1`."

      try do
        transaction(repo, rebuild)
      after
        repo.query!("PRAGMA foreign_keys = ON", [], log: false)
      end
    else
      transaction(repo, rebuild)
    end
  end

  defp transaction(repo, fun) do
    if repo.in_transaction?() do
      fun.()
    else
      {:ok, result} = repo.transaction(fun)
      result
    end
  end

  defp referenced?(repo, table) do
    repo.query!(
      """
      SELECT 1 FROM main.sqlite_schema s, pragma_foreign_key_list(s.name) f
      WHERE s.type = 'table' AND s.name != ? AND f."table" = ?
      LIMIT 1
      """,
      [table, table],
      log: false
    ).rows != []
  end

  defp foreign_keys?(repo), do: repo.query!("PRAGMA foreign_keys", [], log: false).rows == [[1]]

  defp definition!(repo, table) do
    case repo.query!(
           "SELECT sql FROM main.sqlite_schema WHERE type = 'table' AND name = ?",
           [table],
           log: false
         ).rows do
      [[sql]] -> sql
      [] -> raise ArgumentError, "there is no table #{table}"
    end
  end

  # Indexes and triggers go with the dropped table. Indexes SQLite made for a UNIQUE or PRIMARY KEY
  # constraint have no SQL and come back with the table definition.
  defp companions(repo, table) do
    repo.query!(
      """
      SELECT sql FROM main.sqlite_schema
      WHERE tbl_name = ? AND type IN ('index', 'trigger') AND sql IS NOT NULL
      ORDER BY type
      """,
      [table],
      log: false
    ).rows
    |> Enum.map(fn [sql] -> sql end)
  end

  defp run(repo, sql), do: repo.query!(sql, [], log: false)

  @doc false
  # Returns the parenthesised column list and any table options, with the column's NOT NULL
  # removed or added, or `:unchanged`.
  def rewrite(definition, column, nullable?) do
    {open, close} = body_bounds!(definition)
    body = binary_part(definition, open + 1, close - open - 1)
    tail = binary_part(definition, close + 1, byte_size(definition) - close - 1)

    parts = split_top_level(body)

    index =
      Enum.find_index(parts, &(leading_name(&1) == String.downcase(column))) ||
        raise ArgumentError, "the definition of the table has no column #{column}"

    case constrain(Enum.at(parts, index), nullable?) do
      :unchanged -> :unchanged
      part -> {:ok, "(" <> Enum.join(List.replace_at(parts, index, part), ",") <> ")" <> tail}
    end
  end

  @not_null ~r/\s+NOT\s+NULL(\s+ON\s+CONFLICT\s+\w+)?/i

  # Matched against the definition with quoted text and parentheses masked, so NOT NULL inside a
  # CHECK expression or a string default is not the column's.
  defp constrain(part, nullable?) do
    case {Regex.run(@not_null, mask(part), return: :index), nullable?} do
      {[{at, length} | _], true} ->
        binary_part(part, 0, at) <> binary_part(part, at + length, byte_size(part) - at - length)

      {nil, false} ->
        String.trim_trailing(part) <> " NOT NULL"

      _already ->
        :unchanged
    end
  end

  defp mask(part) do
    {masked, _state} =
      part
      |> :binary.bin_to_list()
      |> Enum.map_reduce({0, nil}, fn char, state ->
        next = track(char, state)
        {if(state == {0, nil} and next == {0, nil}, do: char, else: ?_), next}
      end)

    :binary.list_to_bin(masked)
  end

  # The outer parentheses of `CREATE TABLE name (...) [options]`, as byte offsets.
  defp body_bounds!(definition) do
    definition
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.reduce_while({{0, nil}, nil}, &bound/2)
    |> case do
      {open, close} when is_integer(open) and is_integer(close) -> {open, close}
      _unbalanced -> raise ArgumentError, "cannot read the table definition: #{definition}"
    end
  end

  defp bound({?(, at}, {{0, nil}, nil}), do: {:cont, {{1, nil}, at}}
  defp bound({?), at}, {{1, nil}, open}) when is_integer(open), do: {:halt, {open, at}}
  defp bound({char, _at}, {state, open}), do: {:cont, {track(char, state), open}}

  # Splits at commas outside parentheses and quotes.
  defp split_top_level(body) do
    {parts, current, _state} =
      body
      |> :binary.bin_to_list()
      |> Enum.reduce({[], [], {0, nil}}, fn
        ?,, {parts, current, {0, nil} = state} -> {[finish(current) | parts], [], state}
        char, {parts, current, state} -> {parts, [char | current], track(char, state)}
      end)

    Enum.reverse([finish(current) | parts])
  end

  defp finish(reversed), do: reversed |> Enum.reverse() |> :binary.list_to_bin()

  # Parenthesis depth and the quote that is open, if any. A doubled quote inside a quoted name
  # closes and reopens it, which leaves the depth unaffected.
  defp track(char, {depth, quote}) when quote != nil,
    do: {depth, if(char == quote, do: nil, else: quote)}

  defp track(char, {depth, nil}) when char in [?", ?', ?`], do: {depth, char}
  defp track(?[, {depth, nil}), do: {depth, ?]}
  defp track(?(, {depth, nil}), do: {depth + 1, nil}
  defp track(?), {depth, nil}), do: {depth - 1, nil}
  defp track(_char, state), do: state

  defp leading_name(part) do
    part = String.trim_leading(part)

    name =
      case part do
        "\"" <> rest -> rest |> String.split("\"", parts: 2) |> hd()
        "`" <> rest -> rest |> String.split("`", parts: 2) |> hd()
        "[" <> rest -> rest |> String.split("]", parts: 2) |> hd()
        _ -> part |> String.split(~r/\s/, parts: 2) |> hd()
      end

    String.downcase(name)
  end

  defp quote_name(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
end
