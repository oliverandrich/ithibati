defmodule Ithibati.Config do
  @moduledoc """
  The handful of things the application decides and tells Ithibati.

  Ithibati reads what a schema is *built* from at compile time, because a table name and a field's
  type are fixed when the module is compiled. `Application.compile_env/3` makes that safe: Elixir
  records the value it saw and refuses to boot against a different one, rather than running with a
  table name nobody meant.

  Ithibati reads what it is *handed* at runtime: the account schema and the repo. The
  application's modules compile after the dependencies they use.

  A setting that is a rule rather than a value lives with the rule. `Ithibati.Identity.Sessions`
  reads `config :ithibati, session_validity:`, and it is also what decides that a validity is a
  count and a unit.

  `account!/1` is here for the same reason in reverse. What counts as an account is the
  `user_schema` setting, so the guard that refuses everything else belongs beside the setting it
  reads.
  """

  # Not `:prefix`: in Ecto that already means the Postgres schema, which is a separate thing this
  # library may want to support later, and two meanings under one name is a trap for that release.
  alias Ithibati.Schema.Invitation
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

  @doc "The prefix every table Ithibati owns carries."
  def table_prefix, do: @table_prefix

  @doc """
  A table Ithibati owns. `table("keys")` is `"ithibati_keys"` under the default prefix.
  """
  def table(suffix) when is_binary(suffix), do: "#{@table_prefix}_#{suffix}"

  @doc "The type of that table's primary key, and therefore of every `user_id` here."
  def users_key_type, do: @users_key_type

  @doc """
  The account schema an application owns, as a module.

  Ithibati reads this at runtime, and not because a migration runs at runtime: that is true of the
  compile-time settings too. The application's schema module compiles *after* the dependencies it
  uses, so there is nothing to read out of it while Ithibati is compiling. `compile_env` would pin
  an atom from which nothing was derived, and force a recompile that protects nothing.
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
  The invitation schema an application owns, as a module, or `nil` when it invites nobody.

  This setting is optional, unlike the account schema. Ithibati has to be told which schema holds
  invitations before it can answer "who may be invited", but an application with no invitations
  configures nothing and never reaches the module that reads this.

  Ithibati checks the identifier against the account schema's here rather than reading it from
  there. A schema's fields are fixed when its module compiles, and which module is the account's
  is read at runtime, so you state the two separately and this is the first moment both are known.
  """
  def invitation_schema do
    case Application.get_env(:ithibati, :invitation_schema) do
      nil -> nil
      schema -> checked_invitation!(schema)
    end
  end

  @doc """
  The same, for a caller that cannot do anything without one.

  `invitation_schema/0` answers `nil` because the migration has to know when there is no
  invitation table to index. Everything else needs the module, and says so here rather than each
  caller saying it in its own words.
  """
  def invitation_schema! do
    invitation_schema() ||
      raise(
        ArgumentError,
        "config :ithibati, invitation_schema: MyApp.Accounts.Invitation — this library is told " <>
          "which schema holds your invitations before it can look one up."
      )
  end

  defp checked_invitation!(schema) do
    Invitation.invitation_schema?(schema) ||
      raise(
        ArgumentError,
        "config :ithibati, invitation_schema: #{inspect(schema)} — that module does not " <>
          "`use Ithibati.Schema.Invitation`"
      )

    invitee = schema.__ithibati_invitation__(:identifier)
    accounts = user_schema()
    account = accounts.__ithibati__(:identifier)

    invitee == account ||
      raise(
        ArgumentError,
        "#{inspect(schema)} invites by #{inspect(invitee)} and #{inspect(accounts)} is " <>
          "identified by #{inspect(account)} — an invitation has to be addressed to the thing an " <>
          "account is known by, or accepting one cannot fill it in."
      )

    schema
  end

  @doc """
  The repo Ithibati reads and writes through.

  Ithibati reads this at runtime for the same reason it reads `user_schema/0` at runtime: the
  application's repo module compiles after the dependencies it uses. The rejected alternative was
  a repo argument on every public function, which makes every call site louder for a value that
  never varies.
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

  Every function that takes an account goes through this rather than matching `%{id: id}`. With
  `users_key_type: :id`, a struct from somewhere else whose `id` happens to be 1 would otherwise
  be accepted as account 1. With `:binary_id`, the foreign key catches it only afterwards and in
  the database's words.
  """
  def account!(account)

  def account!(%schema{} = account) do
    configured = user_schema()

    schema == configured || refuse(account)

    account
  end

  # `nil` is what an application step that ends in `{:ok, repo.one(query)}` hands over when the query
  # found nothing, and it is the case that will actually happen. Without this it reaches a
  # `%schema{}` clause and fails as a `FunctionClauseError` naming neither this library nor the
  # value.
  def account!(other), do: refuse(other)

  # A struct is named, not inspected: an account carries the identifier, and an exception message is
  # a place it should not turn up.
  defp refuse(%module{}), do: refuse_with("a #{inspect(module)}")
  defp refuse(other), do: refuse_with(inspect(other))

  defp refuse_with(description) do
    raise ArgumentError, "Ithibati: expected a #{inspect(user_schema())}, got #{description}"
  end
end
