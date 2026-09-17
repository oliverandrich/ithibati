defmodule Ithibati.Catalogue.Postgres do
  @moduledoc false

  @key_columns %{binary_id: ["uuid"], id: ["smallint", "integer", "bigint"]}

  def types(:binary), do: ["bytea"]

  def types(:utc_datetime_usec),
    do: ["timestamp without time zone", "timestamp(6) without time zone"]

  def types(type), do: Map.fetch!(@key_columns, type)

  def table(repo, prefix, table) do
    %{rows: [[oid]]} =
      repo.query!(
        "SELECT to_regclass(coalesce(quote_ident($2) || '.', '') || quote_ident($1))::oid",
        [table, prefix],
        log: false
      )

    oid
  end

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
end
