defmodule Ithibati.Catalogue.MySQL do
  @moduledoc false

  def validate!(repo) do
    repo.config()[:migration_default_prefix] &&
      raise ArgumentError, "MySQL supports only the selected database without schema prefixes"

    [[isolation, foreign_keys]] =
      repo.query!("SELECT @@transaction_isolation, @@foreign_key_checks", [], log: false).rows

    isolation == "READ-COMMITTED" ||
      raise ArgumentError, "MySQL requires READ COMMITTED on every connection"

    foreign_keys == 1 ||
      raise ArgumentError, "MySQL requires foreign_key_checks = 1 on every connection"

    :ok
  end

  def table(repo, nil, table) do
    case repo.query!(
           "SELECT TABLE_NAME, ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND TABLE_TYPE = 'BASE TABLE'",
           [table],
           log: false
         ).rows do
      [[name, "InnoDB"]] ->
        {:mysql, name}

      [[_name, engine]] ->
        raise ArgumentError, "MySQL table #{table} requires InnoDB, got #{engine}"

      [] ->
        nil
    end
  end

  def table(_repo, _prefix, _table),
    do: raise(ArgumentError, "MySQL supports only the selected database without schema prefixes")

  def column(repo, table, column) do
    case repo.query!(
           "SELECT COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?",
           [table, to_string(column)],
           log: false
         ).rows do
      [[type]] -> {String.downcase(type), unique?(repo, table, to_string(column))}
      [] -> nil
    end
  end

  def index?(repo, table, name) do
    repo.query!(
      "SELECT 1 FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND INDEX_NAME = ? LIMIT 1",
      [table, to_string(name)],
      log: false
    ).rows != []
  end

  defp unique?(repo, table, column) do
    repo.query!(
      """
      SELECT INDEX_NAME FROM information_schema.STATISTICS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND NON_UNIQUE = 0
      GROUP BY INDEX_NAME
      HAVING COUNT(*) = 1 AND MAX(COLUMN_NAME) = ? AND COUNT(SUB_PART) = 0
      """,
      [table, column],
      log: false
    ).rows != []
  end
end
