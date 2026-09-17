defmodule Ithibati.Catalogue do
  @moduledoc """
  Reads PostgreSQL, SQLite and MySQL table, column and uniqueness metadata.

  `Ithibati.Migration` and `Ithibati.Doctor` use these queries to apply the same checks during
  migration and setup diagnosis. Functions receive the repo explicitly; table lookup also takes
  a PostgreSQL schema prefix. SQLite uses the unprefixed main database; MySQL uses the repo's
  selected database without schema prefixes.
  """

  alias Ithibati.Catalogue.MySQL
  alias Ithibati.Catalogue.SQLite
  alias Ithibati.Config

  # What a `users_key_type` may be, in the words Postgres uses for the column.
  @key_columns %{binary_id: ["uuid"], id: ["smallint", "integer", "bigint"]}

  @doc "Returns an opaque table reference, or nil when the table is absent."
  def table(repo, prefix, name) do
    case repo.__adapter__() do
      Ecto.Adapters.MyXQL -> MySQL.table(repo, prefix, name)
      Ecto.Adapters.SQLite3 -> SQLite.table(repo, prefix, name)
      Ecto.Adapters.Postgres -> table_oid(repo, prefix, name)
    end
  end

  @doc "Database column types compatible with a supported Ecto storage type."
  def types(repo, type) do
    case repo.__adapter__() do
      Ecto.Adapters.MyXQL ->
        mysql_types(type)

      Ecto.Adapters.SQLite3 ->
        sqlite_types(type)

      Ecto.Adapters.Postgres ->
        postgres_types(type)
    end
  end

  defp mysql_types(:binary_id), do: ["binary(16)"]
  defp mysql_types(:id), do: ["bigint", "bigint unsigned"]
  defp mysql_types(:binary), do: ["varbinary(32)"]
  defp mysql_types(:utc_datetime_usec), do: ["datetime(6)"]

  defp sqlite_types(:binary_id),
    do:
      if(Application.get_env(:ecto_sqlite3, :binary_id_type, :string) == :binary,
        do: ["blob"],
        else: ["text"]
      )

  defp sqlite_types(:id), do: ["integer", "bigint", "smallint", "int"]
  defp sqlite_types(:binary), do: ["blob"]
  defp sqlite_types(:utc_datetime_usec), do: ["text"]
  defp postgres_types(:binary), do: ["bytea"]

  defp postgres_types(:utc_datetime_usec),
    do: ["timestamp without time zone", "timestamp(6) without time zone"]

  defp postgres_types(type), do: Map.fetch!(@key_columns, type)

  @doc """
  Returns the relation OID for `table`, or `nil` if the name does not resolve.

  With a prefix, lookup uses that PostgreSQL schema. With `nil`, it uses the connection's search
  path. Identifiers are quoted in PostgreSQL so mixed-case names retain their meaning.
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
  Returns `{database_type, unique?}` for a column, or `nil` if it does not exist.

  Domains resolve to their underlying type. `unique?` requires a non-partial unique index whose
  only key column is this column. Additional included columns are allowed; for example,
  `PRIMARY KEY (id) INCLUDE (email)` qualifies.
  """
  def column(repo, {:mysql, table}, column), do: MySQL.column(repo, table, column)

  def column(repo, {:sqlite, table}, column),
    do: SQLite.column(repo, table, column)

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

  @doc "Returns the table name, qualified with `prefix` when one is supplied, for diagnostic text."
  def qualified(nil, table), do: table
  def qualified(prefix, table), do: "#{prefix}.#{table}"

  @doc """
  Returns `{:ok, description}` when the column meets the configured account-key requirements.

  Returns `{:error, description}` for a missing column, an incompatible database type or missing
  uniqueness. Both migration and doctor checks use this result so they agree on the schema
  Ithibati can reference.
  """
  def key_column(repo, oid, table, column) do
    case column(repo, oid, column) do
      nil ->
        {:error,
         "#{table} has no column #{column}, which is where this library's foreign keys point. " <>
           "Ecto takes that name from the repo's `:migration_foreign_key` setting and defaults " <>
           "it to `id`."}

      {type, unique?} ->
        judge(repo, type, unique?, table, column)
    end
  end

  defp judge(repo, type, unique?, table, column) do
    cond do
      type not in types(repo, Config.users_key_type()) ->
        {:error,
         "config :ithibati, users_key_type: #{inspect(Config.users_key_type())} — but " <>
           "#{table}.#{column} is #{type}. Configure the type that column has, or give it the " <>
           "type you configured; a foreign key cannot bridge the two."}

      not unique? ->
        {:error,
         "#{table}.#{column} carries no unique index, and the database cannot safely let a foreign key " <>
           "point at a column that does not. A primary key, a unique constraint or a unique " <>
           "index on that column will do — beside a composite primary key if you have one."}

      true ->
        {:ok, "#{table}.#{column} is #{type}"}
    end
  end
end
