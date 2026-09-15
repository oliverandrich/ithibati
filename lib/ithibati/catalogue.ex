defmodule Ithibati.Catalogue do
  @moduledoc """
  What Postgres says about the tables an application owns.

  Two callers ask these two questions, and they must not be allowed to disagree.
  `Ithibati.Migration` asks them before it points a foreign key at somebody's account table, and
  `Ithibati.Doctor` asks them afterwards, to say whether what was built still matches what is
  configured. A second copy of either query would answer the same question differently the first
  time somebody corrected one of them.

  Everything here takes its repo and prefix as arguments. The migration has `Ecto.Migration`'s
  `repo/0` and `prefix/0` to hand, and nothing outside a migration does.
  """

  alias Ithibati.Config

  # What a `users_key_type` may be, in the words Postgres uses for the column.
  @key_columns %{binary_id: ["uuid"], id: ["smallint", "integer", "bigint"]}

  @doc """
  The oid of a table, or `nil` when there is none under that prefix.

  This resolves the name the way Ecto resolves the `REFERENCES` clause it emits: qualified when
  there is a prefix, and through the search path when there is not. Postgres does the quoting
  rather than Ithibati, so a table whose name is not lower case answers for itself instead of
  being downcased into a different one.
  """
  def table_oid(repo, prefix, table) do
    %{rows: [[oid]]} =
      repo.query!(
        "SELECT to_regclass(coalesce(quote_ident($2) || '.', '') || quote_ident($1))::oid",
        [table, prefix],
        log: false
      )

    oid
  end

  @doc """
  A column's type and whether one unique index covers it alone, or `nil` when there is no such
  column.

  A domain resolves to what it is built on, because that is what a foreign key compares against.
  The index has to cover that column and nothing else, and it must not be partial, which Postgres
  refuses as a reference target. `indnkeyatts` counts key columns only, so
  `PRIMARY KEY (id) INCLUDE (email)` still qualifies.
  """
  def column(repo, oid, column) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT format_type(
                 CASE WHEN ty.typtype = 'd' THEN ty.typbasetype ELSE a.atttypid END,
                 CASE WHEN ty.typtype = 'd' THEN ty.typtypmod ELSE a.atttypmod END
               ),
               EXISTS (
                 SELECT 1 FROM pg_index x
                 WHERE x.indrelid = a.attrelid AND x.indisunique AND x.indnkeyatts = 1
                   AND x.indkey[0] = a.attnum AND x.indpred IS NULL
               )
        FROM pg_attribute a
        JOIN pg_type ty ON ty.oid = a.atttypid
        WHERE a.attrelid = $1::oid AND a.attname = $2 AND a.attnum > 0 AND NOT a.attisdropped
        """,
        [oid, to_string(column)],
        log: false
      )

    case rows do
      [[type, unique?]] -> {type, unique?}
      [] -> nil
    end
  end

  @doc "A table's name as a message should show it, carrying the prefix when there is one."
  def qualified(nil, table), do: table
  def qualified(prefix, table), do: "#{prefix}.#{table}"

  @doc """
  Whether a table's key column can carry Ithibati's foreign keys. It answers
  `{:ok, description}`, or a sentence saying what is wrong.

  The judgement travels with the query for the reason the query travelled here. The migration
  decides this before it builds and the doctor decides it afterwards, and the two disagreeing is
  worse than either being wrong. A wrong answer out of the SQL is loud. A disagreement about
  *which types are acceptable* means one of them blesses a database the other refuses.
  """
  def key_column(repo, oid, table, column) do
    case column(repo, oid, column) do
      nil ->
        {:error,
         "#{table} has no column #{column}, which is where this library's foreign keys point. " <>
           "Ecto takes that name from the repo's `:migration_foreign_key` setting and defaults " <>
           "it to `id`."}

      {type, unique?} ->
        judge(type, unique?, table, column)
    end
  end

  defp judge(type, unique?, table, column) do
    cond do
      type not in Map.fetch!(@key_columns, Config.users_key_type()) ->
        {:error,
         "config :ithibati, users_key_type: #{inspect(Config.users_key_type())} — but " <>
           "#{table}.#{column} is #{type}. Configure the type that column has, or give it the " <>
           "type you configured; a foreign key cannot bridge the two."}

      not unique? ->
        {:error,
         "#{table}.#{column} carries no unique index, and Postgres will not let a foreign key " <>
           "point at a column that does not. A primary key, a unique constraint or a unique " <>
           "index on that column will do — beside a composite primary key if you have one."}

      true ->
        {:ok, "#{table}.#{column} is #{type}"}
    end
  end
end
