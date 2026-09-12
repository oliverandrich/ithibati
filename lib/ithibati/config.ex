defmodule Ithibati.Config do
  @moduledoc """
  The handful of things a consuming application decides and this library is told.

  All of them are read at compile time, because a schema's table name and a field's type are fixed
  when the module is compiled. `Application.compile_env/3` is what makes that safe: Elixir records
  the value it saw and refuses to boot against a different one rather than running with a table name
  nobody meant.
  """

  # Not `:prefix`: in Ecto that already means the Postgres schema, which is a separate thing this
  # library may want to support later, and two meanings under one name is a trap for that release.
  @table_prefix Application.compile_env(:ithibati, :table_prefix, "ithibati")

  # The type of the *consumer's* account primary key, which this library's tables take a foreign key
  # to. Its own keys are always `binary_id` — that is nobody else's business.
  @users_key_type Application.compile_env(:ithibati, :users_key_type, :binary_id)

  # Checked here rather than where a migration reads it: the three schemas read it too, and a value
  # Ecto happens to accept as a field type compiles all of them happily and is caught only by
  # whoever runs a migration next.
  @users_key_type in [:binary_id, :id] ||
    raise(
      ArgumentError,
      "config :ithibati, users_key_type: must be :binary_id or :id, got: #{inspect(@users_key_type)}"
    )

  @doc "The prefix every table this library owns carries."
  def table_prefix, do: @table_prefix

  @doc """
  A table this library owns — `table("keys")` is `"ithibati_keys"` under the default prefix.
  """
  def table(suffix) when is_binary(suffix), do: "#{@table_prefix}_#{suffix}"

  @doc "The type of that table's primary key, and therefore of every `user_id` here."
  def users_key_type, do: @users_key_type

  @doc """
  The account schema an application owns, as a module.

  Read at runtime rather than compiled in, because what needs it runs at runtime: a migration asks it
  for the table accounts live in and the field they are known by.
  """
  def user_schema do
    schema =
      Application.get_env(:ithibati, :user_schema) ||
        raise(
          ArgumentError,
          "config :ithibati, user_schema: MyApp.Accounts.User — the module that uses " <>
            "Ithibati.Schema.User. This library is told which schema is yours; it does not guess."
        )

    # Checked here rather than left to whatever calls it: a module that is merely wrong fails with
    # `__ithibati__/1 is undefined`, which names neither this library nor the configuration.
    (Code.ensure_loaded?(schema) and function_exported?(schema, :__ithibati__, 1)) ||
      raise(
        ArgumentError,
        "config :ithibati, user_schema: #{inspect(schema)} — that module does not " <>
          "`use Ithibati.Schema.User`"
      )

    schema
  end
end
