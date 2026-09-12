defmodule Ithibati.Config do
  @moduledoc """
  The handful of things a consuming application decides and this library is told.

  What a schema is *built* from is read at compile time, because a table name and a field's type are
  fixed when the module is compiled. `Application.compile_env/3` is what makes that safe: Elixir
  records the value it saw and refuses to boot against a different one rather than running with a
  table name nobody meant.

  What the library is *handed* — the account schema, the repo — is read at runtime, because a
  consuming application's modules compile after the dependencies they use.

  Settings that are a rule rather than a value live with the rule: `config :ithibati,
  token_validity:` is read by `Ithibati.Identity`, which is also what decides that a validity is a
  count and a unit.
  """

  # Not `:prefix`: in Ecto that already means the Postgres schema, which is a separate thing this
  # library may want to support later, and two meanings under one name is a trap for that release.
  alias Ithibati.Schema.User

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

  Read at runtime, and not because a migration runs at runtime — that is true of the compile-time
  settings too. A consuming application's schema module compiles *after* the dependencies it uses,
  so at the moment this library is compiled there is nothing to read out of it: `compile_env` would
  pin an atom from which nothing was derived, forcing a recompile that protects nothing.
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
    User.account_schema?(schema) ||
      raise(
        ArgumentError,
        "config :ithibati, user_schema: #{inspect(schema)} — that module does not " <>
          "`use Ithibati.Schema.User`"
      )

    schema
  end

  @doc """
  The repo this library reads and writes through.

  Read at runtime for the same reason `user_schema/0` is: a consuming application's repo module
  compiles after the dependencies it uses. Rejected alternative — a repo argument on every public
  function, which makes every call site louder for a value that never varies.
  """
  def repo do
    repo =
      Application.get_env(:ithibati, :repo) ||
        raise(
          ArgumentError,
          "config :ithibati, repo: MyApp.Repo — the repo this library reads and writes through. " <>
            "This library is told which repo is yours; it does not guess."
        )

    # Checked here rather than left to the first query: a module that is merely wrong fails with
    # `__adapter__/0 is undefined`, which names neither this library nor the configuration.
    ecto_repo?(repo) ||
      raise(
        ArgumentError,
        "config :ithibati, repo: #{inspect(repo)} — that module is not an Ecto repo"
      )

    repo
  end

  # One predicate rather than two spellings of it, the same reason `account_schema?/1` gives next
  # door: a second caller checking a module by hand is a second thing to find by grep next time.
  defp ecto_repo?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__adapter__, 0)

  @doc """
  An account struct, refused unless it is the configured schema.

  Every function that takes an account goes through this rather than matching `%{id: id}`: with
  `users_key_type: :id` a struct from somewhere else whose `id` happens to be 1 would otherwise be
  accepted as account 1, and with `:binary_id` the foreign key catches it only afterwards and in the
  database's words.
  """
  def account!(%schema{} = account) do
    configured = user_schema()

    schema == configured ||
      raise(
        ArgumentError,
        "Ithibati: expected a #{inspect(configured)}, got a #{inspect(schema)}"
      )

    account
  end
end
