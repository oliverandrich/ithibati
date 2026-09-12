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

  Table names are deliberately **not** options. They are read from the schemas that will go on to
  query these tables — this library's own, and the account schema `config :ithibati, user_schema:`
  names — so the two cannot disagree. An argument could have built `x_tokens` while
  `Ithibati.UserToken` went on looking for `ithibati_tokens`, and nothing would have failed at the
  time the mistake was made.

  The foreign key's type is not an option either, but for a weaker reason: it comes from
  `config :ithibati, users_key_type:`, which an application can still set to something its own
  `@primary_key` does not agree with.
  """
  use Ecto.Migration

  alias Ithibati.Bootstrap
  alias Ithibati.Config
  alias Ithibati.RecoveryCode
  alias Ithibati.UserKey
  alias Ithibati.UserToken

  @current_version 1

  # Ordered as they are created; `down` reverses it, so a table added to one clause cannot be
  # forgotten in the other.
  @v1_schemas [UserKey, RecoveryCode, UserToken, Bootstrap]

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
    schema = Config.user_schema()

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
      schema: schema,
      users_table: source(schema)
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

    create table(source(Bootstrap), primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Nilified rather than cascaded: the account that set an instance up may be deleted, and the
      # instance is still set up. A cascade here would make a second setup possible again.
      add :user_id, references(opts.users_table, type: key_type(), on_delete: :nilify_all)
      add :claimed, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    # The guarantee. Every row carries the same value, so at most one row can exist.
    create unique_index(source(Bootstrap), [:claimed])

    create_account_index(opts)
  end

  defp step(1, :down, opts) do
    for schema <- Enum.reverse(@v1_schemas), do: drop(table(source(schema)))

    drop_account_index(opts)
  end

  # The account lookup this library performs is `Repo.get_by/3`, which raises on a second match
  # rather than signing anybody in — so the unique index on the identifier is not decoration, and
  # leaving it to an application to remember would be requiring something and then hoping.
  #
  # Skipped when the schema passed `constraint_name:`, which is how an application says it maintains
  # its own — a partial, expression or composite index this library has no business guessing at.
  # Why this library creates an index on a table it does not own: `docs/design.md`, decision 2.
  defp create_account_index(opts) do
    if opts.schema.__ithibati__(:unique_index),
      do: create(identifier_index(opts)),
      else: confirm_index!(opts)
  end

  defp drop_account_index(opts) do
    # `drop_if_exists`, because the decision is read from configuration that can change between the
    # two runs.
    if opts.schema.__ithibati__(:unique_index), do: drop_if_exists(identifier_index(opts))
  end

  defp identifier_index(opts) do
    unique_index(opts.users_table, [identifier(opts)], index_opts(opts))
  end

  defp identifier(opts), do: opts.schema.__ithibati__(:identifier)

  defp index_opts(opts) do
    case opts.schema.__ithibati__(:constraint) do
      nil -> []
      name -> [name: name]
    end
  end

  # Asked of `pg_index` rather than of the name: `to_regclass` answers for any relation that happens
  # to be called that — a table, a view, a non-unique index, an index on another column would all
  # pass. What the account lookup needs is a unique index over exactly this column.
  defp confirm_index!(opts) do
    # `create/1` only queues; the query below runs at once, so flush first or it cannot see an index
    # the calling migration has just asked for.
    flush()

    %{rows: rows} =
      repo().query!(
        """
        SELECT 1
        FROM pg_index x
        JOIN pg_class t ON t.oid = x.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = x.indkey[0]
        WHERE x.indisunique AND x.indnkeyatts = 1
          AND t.relname = $1 AND n.nspname = coalesce($2, current_schema()) AND a.attname = $3
        LIMIT 1
        """,
        [opts.users_table, schema_prefix(), to_string(identifier(opts))],
        log: false
      )

    rows != [] ||
      raise(
        ArgumentError,
        "#{inspect(opts.schema)} passes `unique_index: false`, so this library expects the " <>
          "application to maintain a unique index on #{opts.users_table}.#{identifier(opts)} — " <>
          "there is none. Create it, or drop the option and let this library create one."
      )
  end

  # The migrator's prefix, or the one the repo migrates into by default — which is what
  # `Ecto.Migration` itself falls back to when it creates a table.
  defp schema_prefix, do: prefix() || repo().config()[:migration_default_prefix]

  defp source(schema), do: schema.__schema__(:source)

  defp key_type, do: reference_type(UserKey.__schema__(:type, :user_id))
end
