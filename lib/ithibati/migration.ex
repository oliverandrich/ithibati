defmodule Ithibati.Migration do
  @moduledoc """
  Creates Ithibati's tables, as code and not as a file to copy.

  You write an ordinary migration of your own and call this from it.
  [Getting started](getting_started.md#4-the-migration) carries the template and the configuration
  it reads. What follows is what the two functions take.

  ## Options

    * `:version` — the schema version to build. Required. An unpinned call builds a different set
      of tables depending on when it runs, and a rollback that undoes neither.
    * `:from` — the version already present, exclusive. Defaults to `0`, a database with none of
      these tables. A release that adds to the schema reaches an application as a second migration
      of its own saying where it starts. Ecto records what has already been applied in that
      application's own `schema_migrations`.

  Table names are deliberately **not** options. The migration reads them from the schemas that go
  on to query these tables: Ithibati's own, and the account schema that `config :ithibati,
  user_schema:` names. The two therefore cannot disagree. An argument could have built
  `x_sessions` while `Ithibati.Session` went on looking for `ithibati_sessions`, and nothing
  would have failed
  at the time the mistake was made.

  The foreign key's type is not an option either. `config :ithibati, users_key_type:` is compiled
  into the schemas, and this migration reads it back out of one of them. An application can still
  configure a type its own account table does not have, so the migration asks the column these
  foreign keys will point at what it is before it builds anything, and refuses a disagreement
  instead of half-applying it.
  """
  use Ecto.Migration

  require Logger

  alias Ithibati.Bootstrap
  alias Ithibati.Catalogue
  alias Ithibati.Config
  alias Ithibati.RecoveryCode
  alias Ithibati.Session
  alias Ithibati.UserKey

  @current_version 1

  # Ordered as they are created; `down` reverses it, so a table added to one clause cannot be
  # forgotten in the other.
  @v1_schemas [UserKey, RecoveryCode, Session, Bootstrap]

  @doc "The newest schema version this release knows."
  def current_version, do: @current_version

  @doc "Builds Ithibati's tables. See the module documentation for options."
  def up(opts) do
    opts = settings(opts)
    confirm_tables!(opts)
    Enum.each((opts.from + 1)..opts.version//1, &step(&1, :up, opts))
  end

  @doc "Removes what the matching `up/1` built."
  def down(opts) do
    opts = settings(opts)
    Enum.each(opts.version..(opts.from + 1)//-1, &step(&1, :down, opts))
  end

  # `:id` is the schema-side name for an integer key, and Ecto renders it as `integer` in a
  # migration. But the Phoenix default it describes is `bigserial`, so a foreign key declared that
  # way holds accounts only up to two billion and then fails on insert. Named here, and not left to
  # `references(type: :bigserial)`, which reaches the same column through a Postgres-only branch of
  # the adapter.
  @doc """
  The columns an invitation table has to carry, for the migration that creates it.

  This is the counterpart to `Ithibati.Schema.Invitation.ithibati_invitation/0`. That macro
  declares the fields, and this one adds the columns behind them. Both read the identifier off
  the schema you configured, so the two cannot name different things. That is the mistake this
  replaces: a `token_hash` written `:string` instead of `:binary` migrates without complaint and
  fails at the first invitation.

  Call it inside a `create table/2` of your own:

      create table(:invitations) do
        Ithibati.Migration.invitation_columns(version: 1)

        add :role, Ecto.Enum, values: [:admin, :author]
        timestamps(type: :utc_datetime_usec)
      end

  It adds exactly four columns, and this list is the whole of it:

    * the identifier your invitation schema declares, `:string`, `null: false`
    * `:token_hash`, `:binary`, `null: false`
    * `:expires_at`, `:utc_datetime_usec`, `null: false`
    * `:accepted_at`, `:utc_datetime_usec`, nullable. `NULL` is what "not accepted yet" means,
      and `Ithibati.Identity.Invitations.fetch/1` reads it that way

  The virtual `:token` the schema declares is not among them, because Ithibati never stores the
  secret.

  `version:` is required, for the reason `up/1` gives. A migration is a record of what was built,
  and an unpinned call expands against whichever release is installed the next time somebody sets
  up a database from scratch.

  Nothing here is compulsory. `up/1` checks an invitation table that already exists, or one you
  would rather write out, either way.
  """
  def invitation_columns(opts) do
    pinned!(opts, "invitation_columns/1")

    identifier = identifier(Config.invitation_schema!())

    # Ecto prints `create table invitations` and nothing about what went into it, so a reader
    # who wants to know what this added otherwise has to ask the database afterwards.
    Logger.info("ithibati: adding #{identifier}, token_hash, expires_at, accepted_at")

    add(identifier, :string, null: false)
    add(:token_hash, :binary, null: false)
    add(:expires_at, :utc_datetime_usec, null: false)
    add(:accepted_at, :utc_datetime_usec)
  end

  @doc """
  The unique index on an invitation table's `token_hash`, for a migration of your own.

  `up/1` creates this index as part of its own run, so an application that configured
  `invitation_schema:` before migrating never needs this function. It exists for the case where
  you turn invitations on *afterwards*: `up/1` has been recorded as applied and will not run
  again, and the token in an invitation link is a bearer secret looked up by that digest.

      defmodule MyApp.Repo.Migrations.AddInvitations do
        use Ecto.Migration

        def change do
          create table(:invitations) do
            Ithibati.Migration.invitation_columns(version: 1)

            timestamps(type: :utc_datetime_usec)
          end

          Ithibati.Migration.invitation_index(version: 1)
        end
      end

  It is safe to call either way. It creates the index only if it is not already there, and `up/1`
  does the same, so the two cannot collide however they are ordered.
  """
  def invitation_index(opts) do
    pinned!(opts, "invitation_index/1")

    # Through the same description and the same create-and-confirm `up/1` uses. No second spelling
    # of the index here: the promise above, that the two paths cannot collide however they are
    # ordered, rests on them building the same thing, and on both noticing when
    # `create_if_not_exists` matched a name that is not ours.
    %{invitation: Config.invitation_schema!()}
    |> invitation_indexes()
    |> Enum.each(&maintain_index/1)
  end

  # `version:` is required, and pinned, for the reason `up/1` gives. One check, not one per
  # entry point. The range is `@current_version`'s to state, and three copies of it is three
  # places to edit when it gains a second value.
  defp pinned!(opts, caller) do
    version = Keyword.get(opts, :version)

    version in 1..@current_version//1 ||
      raise ArgumentError,
            "#{caller} needs `version:`, pinned the way `up/1` is — 1 to " <>
              "#{@current_version} in this release, got: #{inspect(version)}"
  end

  defp identifier(schema), do: schema.__ithibati_invitation__(:identifier)

  @doc false
  def reference_type(:id), do: :bigint
  def reference_type(other), do: other

  defp settings(opts) do
    schema = Config.user_schema()

    version =
      Keyword.get(opts, :version) ||
        raise(ArgumentError, "version: is required — pin the one this migration was written for")

    from = Keyword.get(opts, :from, 0)

    # Refused, never tolerated. A version this release does not know reaches no clause, and a
    # starting point at or above it builds nothing at all while Ecto records the migration as
    # applied. A consumer would find out at the first query.
    require!(version, 1..@current_version//1, "version", "1..#{@current_version}")
    require!(from, 0..(version - 1)//1, "from", "0..#{version - 1}")

    %{
      version: version,
      from: from,
      schema: schema,
      users_table: source(schema),
      invitation: Config.invitation_schema()
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
      # `:text`, not a sized column. The limit on a label is a display decision, applied in
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

    # `redeem/2` spends a code with a single statement and reads its answer from the row count, so a
    # second row with the same digest would spend both and answer neither.
    create unique_index(source(RecoveryCode), [:code_hash])
    create index(source(RecoveryCode), [:user_id])

    create table(source(Session), primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, holder, null: false
      add :token_hash, :binary, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(source(Session), [:token_hash])
    create index(source(Session), [:user_id])

    create table(source(Bootstrap), primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Nilified, not cascaded. The account that set an instance up may be deleted, and the
      # instance is still set up. A cascade here would make a second setup possible again.
      add :user_id, references(opts.users_table, type: key_type(), on_delete: :nilify_all)
      add :claimed, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    # The guarantee. Every row carries the same value, so at most one row can exist.
    create unique_index(source(Bootstrap), [:claimed])

    Enum.each(application_indexes(opts), &maintain_index/1)
  end

  defp step(1, :down, opts) do
    for schema <- Enum.reverse(@v1_schemas), do: drop(table(source(schema)))

    opts |> application_indexes() |> Enum.reverse() |> Enum.each(&drop_index/1)
  end

  # Every index this library maintains on a table it does not own, as a list, so that a third such
  # table is an entry and not another pair of functions. Why it maintains them at all: a
  # changeset cannot keep an identifier unique against a concurrent insert, so the uniqueness has
  # to be the database's.
  defp application_indexes(opts), do: [account_index(opts) | invitation_indexes(opts)]

  # Two people registering the same identifier at the same moment both pass the changeset's
  # uniqueness check and both insert, unless the database refuses the second. So the unique index
  # is not decoration, and leaving it to an application to remember would be requiring something
  # and then hoping. `Ithibati.Schema.User.identifier_taken?/1` is how the application learns
  # that this is what a refused insert collided on.
  #
  # `unique_index: false` is how an application says it maintains its own: a partial, expression or
  # composite index this library has no business guessing at. The index is then checked instead.
  defp account_index(opts) do
    %{
      schema: opts.schema,
      table: opts.users_table,
      column: opts.schema.__ithibati__(:identifier),
      create?: opts.schema.__ithibati__(:unique_index),
      name: opts.schema.__ithibati__(:constraint)
    }
  end

  # Empty for a consumer who invites nobody: no invitation schema, no such table, nothing to index.
  # Otherwise the digest in a link is looked up the same way an identifier is, so it wants the same
  # kind of index.
  defp invitation_indexes(%{invitation: nil}), do: []

  defp invitation_indexes(%{invitation: schema}) do
    [
      %{
        schema: schema,
        table: source(schema),
        column: :token_hash,
        create?: schema.__ithibati_invitation__(:unique_index),
        name: schema.__ithibati_invitation__(:constraint)
      }
    ]
  end

  # `create_if_not_exists`, so that the order stops mattering: a consumer who turned invitations
  # on later made this index in a migration of their own with `invitation_index/1`, and one who
  # rebuilds that database from scratch runs both. Neither should collide with the other.
  #
  # The confirmation afterwards is what that costs. Postgres matches `IF NOT EXISTS` on the index
  # *name* alone, so an index of the application's that happens to carry the name Ecto derives
  # turns the create into a silent no-op where plain `create` raised. `UNIQUE (email) WHERE
  # deleted_at IS NULL` is the shape that does it, and it permits exactly the two rows the account
  # lookup cannot survive. So both branches end in the same question: is the column uniquely
  # indexed now.
  defp maintain_index(index) do
    if index.create?, do: create_if_not_exists(index_for(index))

    confirm_index!(index)
  end

  defp drop_index(index) do
    # `drop_if_exists`, because the decision is read from configuration that can change between the
    # two runs.
    if index.create?, do: drop_if_exists(index_for(index))
  end

  # `name: nil` is not a missing name. `Ecto.Migration.index/3` fills it in with the one it derives.
  defp index_for(index), do: unique_index(index.table, [index.column], name: index.name)

  # Asked of `pg_index`, not of the name. `to_regclass` answers for any relation that happens
  # to be called that: a table, a view, a non-unique index, an index on another column would all
  # pass. What the account lookup needs is a unique index over exactly this column.
  defp confirm_index!(index) do
    # `create/1` only queues; the query below runs at once, so flush first or it cannot see an index
    # the calling migration has just asked for. `confirm_tables!/1` has already flushed by the time
    # this runs, and this one stays anyway: a check that depends on a flush somewhere else is a check
    # that breaks when two lines are swapped, and flushing an empty queue costs nothing.
    #
    # A partial index is the one a consumer is most likely to have: `UNIQUE (email) WHERE
    # deleted_at IS NULL` looks like a unique index and lets two rows share the value, which is
    # the `Ecto.MultipleResultsError` this check exists to prevent. `Ithibati.Catalogue` rules it
    # out along with the rest, which is why this asks the same question the account key is asked.
    flush()

    match?(
      {_type, true},
      Catalogue.column(repo(), table_oid!(index.table), index.column)
    ) ||
      raise(ArgumentError, unindexed(index))
  end

  defp unindexed(%{create?: false} = index) do
    "#{inspect(index.schema)} passes `unique_index: false`, so this library expects the " <>
      "application to maintain a unique index on #{index.table}.#{index.column} — there is " <>
      "none. Create it, or drop the option and let this library create one."
  end

  defp unindexed(%{create?: true} = index) do
    "this library asked for a unique index on #{index.table}.#{index.column} and the table " <>
      "still has none. Something else already answers to #{index_for(index).name}, and " <>
      "`CREATE UNIQUE INDEX IF NOT EXISTS` matches on that name alone — a partial index such " <>
      "as `UNIQUE (#{index.column}) WHERE …` is the usual one. Rename it, or drop it and let " <>
      "this library create the index the account lookup needs."
  end

  # What Postgres calls the column a foreign key of this type can point at. An `:id` account table
  # is `bigserial` by default but `serial` is a legal choice, and Postgres references across the
  # integer widths happily. They share an operator family.

  # What `references/2` will demand of the account table, asked before anything is built and not
  # discovered from inside it. The column it points at has to exist, be a type this foreign key can
  # compare against, and carry a unique index. A unique index is what Postgres requires of any
  # referenced column, not a primary key, so a composite primary key with `UNIQUE (id)` beside it
  # is a legal account table, and this is why it passes.
  defp confirm_tables!(opts) do
    # Nothing to confirm while tearing down, and `flush/0` refuses to run in that direction at all.
    # A consumer whose `change/0` calls `up/1` would otherwise fail its rollback here.
    if direction() == :up do
      # `create/1` only queues, and an application is allowed to create its tables and call `up/1`
      # in one migration.
      flush()

      # Every table this library reads without owning, and every column on each that it goes on
      # to read. Asked for first, so that a missing one is a word about the setting that named it
      # and not a Postgres error about a relation or a column nobody mentioned.
      Enum.each(application_indexes(opts), &confirm_indexed_column!/1)
      confirm_invitation_columns!(opts)

      confirm_account_key!(opts)
    end
  end

  # The column is the application's to add; the index on it is this library's to create. That line
  # is not obvious from the outside, so a column that is not there is answered with where it
  # belongs, and not with the `undefined_column` Postgres raises when the index is built.
  defp confirm_indexed_column!(index) do
    oid = table_oid!(index.table)

    Catalogue.column(repo(), oid, index.column) ||
      raise(
        ArgumentError,
        "#{inspect(index.schema)} declares #{qualified(index.table)}.#{index.column}, and the " <>
          "table has no such column. The column is yours to add — in the migration that creates " <>
          "the table, or in one of its own — and this library creates the unique index on it."
      )
  end

  # The three columns beyond the identifier that an invitation table has to carry, with what
  # Postgres has to call them. The schema declares all four and the migration indexes one, so
  # without this a `token_hash` somebody wrote as `:string` migrates green and fails at the first
  # invitation, later and further from the mistake than any other disagreement here.
  #
  # The identifier is deliberately absent: `citext` is a shape this library supports, and an
  # application whose accounts use it wants its invitations to match.
  @invitation_columns [
    {:token_hash, ["bytea"]},
    {:expires_at, ["timestamp without time zone", "timestamp(6) without time zone"]},
    {:accepted_at, ["timestamp without time zone", "timestamp(6) without time zone"]}
  ]

  defp confirm_invitation_columns!(%{invitation: nil}), do: :ok

  defp confirm_invitation_columns!(%{invitation: schema}) do
    table = source(schema)
    oid = table_oid!(table)

    Enum.each(@invitation_columns, fn {column, accepted} ->
      case Catalogue.column(repo(), oid, column) do
        nil ->
          raise ArgumentError,
                "#{inspect(schema)} declares #{qualified(table)}.#{column}, and the table has " <>
                  "no such column. `ithibati_invitation/0` declares four columns and this is " <>
                  "one of them; the table is yours to create."

        {type, _unique?} ->
          type in accepted ||
            raise ArgumentError,
                  "#{qualified(table)}.#{column} is #{type}, and this library reads it as " <>
                    "#{Enum.join(accepted, " or ")}. `ithibati_invitation/0` declares it, so " <>
                    "the column your migration adds has to match."
      end
    end)
  end

  defp confirm_account_key!(opts) do
    oid = table_oid!(opts.users_table)

    case Catalogue.key_column(repo(), oid, opts.users_table, account_key_column(opts)) do
      {:ok, _described} -> :ok
      {:error, message} -> raise ArgumentError, message
    end
  end

  # Read off the reference, never assumed. Ecto points a foreign key at `:id` unless the repo
  # moves it with `:migration_foreign_key`, and a check that guessed would pass tables the migration
  # then fails on.
  defp account_key_column(opts) do
    references(opts.users_table, type: key_type()).column
  end

  defp table_oid!(table) do
    Catalogue.table_oid(repo(), schema_prefix(), table) ||
      raise(
        ArgumentError,
        "there is no table #{qualified(table)} — this library's migration reads and references " <>
          "the tables your application owns, so it runs after the migrations that create them."
      )
  end

  defp qualified(table), do: Catalogue.qualified(schema_prefix(), table)

  # The migrator's prefix, or the one the repo migrates into by default, which is what
  # `Ecto.Migration` itself falls back to when it creates a table.
  defp schema_prefix, do: prefix() || repo().config()[:migration_default_prefix]

  defp source(schema), do: schema.__schema__(:source)

  defp key_type, do: reference_type(UserKey.__schema__(:type, :user_id))
end
