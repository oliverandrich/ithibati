defmodule Ithibati.SchemaTimestampsTest do
  @moduledoc """
  Every datetime this library stores keeps microseconds, in the schema *and* in the column.

  Two halves, because each is blind to the other's mistake. A schema field of `:utc_datetime`
  truncates on write even where the column keeps microseconds, so every value is rounded to the
  second and nothing notices until a sort comes out wrong — the schema half catches that. The
  column half catches a column written with an explicit precision, which Ecto's own migrations
  never emit (the Postgres adapter maps every datetime type to a bare `timestamp`) but a
  hand-written one can.

  The schemas are discovered rather than listed: a fourth table has to be classified here before it
  can pass.
  """
  use Ithibati.DataCase, async: true

  @precision 6

  defp schemas do
    {:ok, modules} = :application.get_key(:ithibati, :modules)

    Enum.filter(modules, &(Code.ensure_loaded?(&1) and function_exported?(&1, :__schema__, 1)))
  end

  defp datetime_fields(schema) do
    for field <- schema.__schema__(:fields),
        type = schema.__schema__(:type, field),
        type in [:utc_datetime, :utc_datetime_usec, :naive_datetime, :naive_datetime_usec],
        do: {field, type}
  end

  test "the suite has schemas to check, so this cannot pass by finding none" do
    assert length(schemas()) >= 3
    assert Enum.all?(schemas(), &(datetime_fields(&1) != []))
  end

  test "every datetime field is :utc_datetime_usec" do
    for schema <- schemas(), {field, type} <- datetime_fields(schema) do
      assert type == :utc_datetime_usec, "#{inspect(schema)}.#{field} is #{inspect(type)}"
    end
  end

  test "and so is the column behind it" do
    for schema <- schemas(), {field, _type} <- datetime_fields(schema) do
      assert column_precision(schema.__schema__(:source), field) == @precision,
             "#{schema.__schema__(:source)}.#{field} does not keep microseconds"
    end
  end

  defp column_precision(table, column) do
    %{rows: [[precision]]} =
      TestRepo.query!(
        "SELECT datetime_precision FROM information_schema.columns
         WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2",
        [table, to_string(column)],
        log: false
      )

    precision
  end
end
