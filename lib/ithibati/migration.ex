defmodule Ithibati.Migration do
  @moduledoc """
  Creates this library's tables, as code rather than as a file to copy.

  A consuming application writes an ordinary migration of its own and calls this from it. The README
  carries the template and the configuration it reads; what follows is what the two functions take.

  ## Options

    * `:version` — the schema version to build. Required: an unpinned call means a different set of
      tables depending on when it runs, and a rollback that undoes neither.
    * `:from` — the version already present, exclusive. Defaults to `0`, a database with none of
      these tables. A release that adds to the schema reaches a consumer as a second migration of
      their own saying where it starts; what has already been applied is recorded where Ecto records
      it, in that application's own `schema_migrations`.
    * `:users_table` — the account table the foreign keys point at. Defaults to the configured one.

  The tables' own names and the type of their foreign key are deliberately **not** options. They are
  read from the schemas that will go on to query these tables, so the two cannot disagree — an
  argument could have built `x_tokens` while `Ithibati.UserToken` went on looking for
  `ithibati_tokens`, and nothing would have failed at the time the mistake was made.
  """
  use Ecto.Migration

  alias Ithibati.Config
  alias Ithibati.RecoveryCode
  alias Ithibati.UserKey
  alias Ithibati.UserToken

  @current_version 1

  # Ordered as they are created; `down` reverses it, so a table added to one clause cannot be
  # forgotten in the other.
  @v1_schemas [UserKey, RecoveryCode, UserToken]

  @doc "The newest schema version this release knows."
  def current_version, do: @current_version

  @doc "Builds this library's tables. See the module documentation for options."
  def up(opts) do
    opts = settings(opts)
    Enum.each((opts.from + 1)..opts.version//1, &step(&1, :up, opts))
  end

  @doc "Removes what the matching `up/1` built."
  def down(opts) do
    opts = settings(opts)
    Enum.each(opts.version..(opts.from + 1)//-1, &step(&1, :down, opts))
  end

  # `:id` is the schema-side name for an integer key, and Ecto renders it as `integer` in a
  # migration — but the Phoenix default it describes is `bigserial`, so a foreign key declared that
  # way holds accounts only up to two billion and then fails on insert. Named rather than left to
  # `references(type: :bigserial)`, which reaches the same column through a Postgres-only branch of
  # the adapter.
  @doc false
  def reference_type(:id), do: :bigint
  def reference_type(other), do: other

  defp settings(opts) do
    version =
      Keyword.get(opts, :version) ||
        raise(ArgumentError, "version: is required — pin the one this migration was written for")

    from = Keyword.get(opts, :from, 0)

    # Refused rather than tolerated: a version this release does not know reaches no clause, and a
    # starting point at or above it builds nothing at all while Ecto records the migration as
    # applied — a consumer would find out at the first query.
    require!(version, 1..@current_version//1, "version", "1..#{@current_version}")
    require!(from, 0..(version - 1)//1, "from", "0..#{version - 1}")

    %{
      version: version,
      from: from,
      users_table: Keyword.get(opts, :users_table, Config.users_table())
    }
  end

  defp require!(value, allowed, name, described) do
    value in allowed ||
      raise(ArgumentError, "#{name} must be #{described}, got: #{inspect(value)}")
  end

  defp step(1, :up, opts) do
    holder = references(opts.users_table, type: key_type(), on_delete: :delete_all)

    create table(source(UserKey), primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, holder, null: false
      add :key_id, :binary, null: false
      add :public_key, :binary, null: false
      # `:text` rather than a sized column: the limit on a label is a display decision, applied in
      # the changeset. See `Ithibati.UserKey`.
      add :label, :text
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(source(UserKey), [:key_id])
    create index(source(UserKey), [:user_id])

    create table(source(RecoveryCode), primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, holder, null: false
      add :code_hash, :binary, null: false
      add :used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(source(RecoveryCode), [:user_id])

    create table(source(UserToken), primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, holder, null: false
      add :token, :binary, null: false
      add :context, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(source(UserToken), [:token])
    create index(source(UserToken), [:user_id])
  end

  defp step(1, :down, _opts) do
    for schema <- Enum.reverse(@v1_schemas), do: drop(table(source(schema)))
  end

  defp source(schema), do: schema.__schema__(:source)

  defp key_type, do: reference_type(UserKey.__schema__(:type, :user_id))
end
