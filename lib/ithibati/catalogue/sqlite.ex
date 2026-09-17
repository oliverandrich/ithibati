defmodule Ithibati.Catalogue.SQLite do
  @moduledoc false

  def types(:binary_id),
    do:
      if(Application.get_env(:ecto_sqlite3, :binary_id_type, :string) == :binary,
        do: ["blob"],
        else: ["text"]
      )

  def types(:id), do: ["integer", "bigint", "smallint", "int"]
  def types(:binary), do: ["blob"]
  def types(:utc_datetime_usec), do: ["text"]

  def validate!(repo) do
    repo.config()[:migration_default_prefix] &&
      raise ArgumentError, "SQLite supports only the unprefixed main database"

    repo.query!("PRAGMA foreign_keys", [], log: false).rows == [[1]] ||
      raise ArgumentError, "SQLite requires foreign_keys: :on on every connection"

    :ok
  end

  def table(repo, nil, table) do
    case repo.query!(
           "SELECT name FROM main.sqlite_schema WHERE type = 'table' AND name = ?",
           [table],
           log: false
         ).rows do
      [[name]] -> {:sqlite, name}
      [] -> nil
    end
  end

  def table(_repo, _prefix, _table),
    do: raise(ArgumentError, "SQLite supports only the unprefixed main database")

  def column(repo, {:sqlite, table}, column) do
    column = to_string(column)

    rows =
      repo.query!("SELECT name, type, pk FROM pragma_table_xinfo(?) WHERE hidden = 0", [table],
        log: false
      ).rows

    case Enum.find(rows, fn [name, _type, _pk] -> name == column end) do
      nil ->
        nil

      [_, type, pk] ->
        type = String.downcase(type)
        primary? = pk > 0 and Enum.count(rows, fn [_, _, key] -> key > 0 end) == 1
        {type, primary? or unique?(repo, table, column)}
    end
  end

  defp unique?(repo, table, column) do
    repo.query!(
      ~s|SELECT name FROM pragma_index_list(?) WHERE "unique" = 1 AND partial = 0|,
      [table],
      log: false
    ).rows
    |> Enum.any?(fn [index] ->
      repo.query!(
        ~s|SELECT name FROM pragma_index_xinfo(?) WHERE "key" = 1 ORDER BY seqno|,
        [index],
        log: false
      ).rows == [[column]]
    end)
  end
end
