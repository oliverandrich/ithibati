defmodule Ithibati.Catalogue do
  @moduledoc """
  Reads PostgreSQL, SQLite and MySQL table, column and uniqueness metadata.

  `Ithibati.Migration` and `Ithibati.Doctor` use these queries to apply the same checks during
  migration and setup diagnosis. Functions receive the repo explicitly; table lookup also takes
  a PostgreSQL schema prefix. SQLite uses the unprefixed main database; MySQL uses the repo's
  selected database without schema prefixes.
  """

  alias Ithibati.Catalogue.MySQL
  alias Ithibati.Catalogue.Postgres
  alias Ithibati.Catalogue.SQLite
  alias Ithibati.Config

  @doc "Returns an opaque table reference, or nil when the table is absent."
  def table(repo, prefix, name), do: adapter(repo).table(repo, prefix, name)

  @doc "Database column types compatible with a supported Ecto storage type."
  def types(repo, type), do: adapter(repo).types(type)

  defp adapter(repo) do
    case repo.__adapter__() do
      Ecto.Adapters.Postgres -> Postgres
      Ecto.Adapters.SQLite3 -> SQLite
      Ecto.Adapters.MyXQL -> MySQL
    end
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

  def column(repo, oid, column), do: Postgres.column(repo, oid, column)

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
