defmodule Ithibati.Migration do
  @moduledoc """
  Creates or removes Ithibati's versioned database schema from an application migration.

      defmodule MyApp.Repo.Migrations.AddIthibati do
        use Ecto.Migration

        def up, do: Ithibati.Migration.up(version: 2)
        def down, do: Ithibati.Migration.down(version: 2)
      end

  Use explicit `up/0` and `down/0`, not `change/0`: catalogue checks flush queued DDL and
  cannot be reversed automatically by Ecto.

  Create the account table and identifier column first. If invitations are configured, their
  table must also exist when `up/1` validates the application tables.

  ## Options

    * `:version` — required target schema version supported by the installed release.
    * `:from` — existing version, exclusive; defaults to `0`. A later upgrade uses a new
      application migration with the original version as `:from`.

  Keep versions pinned in applied migrations. `current_version/0` reports the newest version
  this release supports. `down/1` removes the changes covered by the matching range.

  Version 3 adds the operator-code digest table used by protected first claims.
  Table names and account foreign-key types come from the configured schemas. `up/1` verifies
  required columns, key types and unique indexes before creating its tables. The application
  continues to own its account and invitation tables.

  [Getting started](getting_started.md#4-the-migration) shows initial setup;
  [Configuration and schemas](configuration.md#migrations) covers index ownership and upgrades.
  """
  use Ecto.Migration

  require Logger

  alias Ithibati.Bootstrap
  alias Ithibati.Catalogue
  alias Ithibati.Catalogue.MySQL
  alias Ithibati.Catalogue.SQLite
  alias Ithibati.Challenge
  alias Ithibati.Config
  alias Ithibati.RecoveryCode
  alias Ithibati.Session
  alias Ithibati.SetupCode
  alias Ithibati.UserKey

  @current_version 4

  # Ordered as they are created; `down` reverses it, so a table added to one clause cannot be
  # forgotten in the other.
  @v1_schemas [UserKey, RecoveryCode, Session, Bootstrap]

  @doc "The newest schema version this release knows."
  def current_version, do: @current_version

  @doc "Builds Ithibati's tables. See the module documentation for options."
  def up(opts) do
    opts = settings(opts)

    if repo().__adapter__() == Ecto.Adapters.SQLite3,
      do: SQLite.validate!(repo())

    if repo().__adapter__() == Ecto.Adapters.MyXQL, do: MySQL.validate!(repo())

    confirm_tables!(opts)
    Enum.each((opts.from + 1)..opts.version//1, &step(&1, :up, opts))
  end

  @doc "Removes what the matching `up/1` built."
  def down(opts) do
    opts = settings(opts)
    Enum.each(opts.version..(opts.from + 1)//-1, &step(&1, :down, opts))
  end

  @doc """
  Adds the required invitation columns inside an application's `create table` block.

  The configured invitation schema supplies the identifier field name. `version:` is required
  and must name a supported schema version.

      create table(:invitations) do
        Ithibati.Migration.invitation_columns(version: 1)

        add :role, :string
        timestamps(type: :utc_datetime_usec)
      end

  Declare `field :role, Ecto.Enum, values: [:admin, :author]` in the application's Ecto schema
  when using that string column as an enum.

  The helper adds:

    * the identifier, `:string` by default, `null: false`
    * `:token_hash`, `:binary`, `null: false`
    * `:expires_at`, `:utc_datetime_usec`, `null: false`
    * `:accepted_at`, `:utc_datetime_usec`, nullable for pending invitations

  The schema's virtual `:token` is not stored. Add application-specific fields and timestamps
  separately. `:type` overrides only the identifier's database type and is passed to
  `Ecto.Migration.add/3`. For `type: :citext`, install the PostgreSQL extension first.
  See the [invitation guide](invitations.md#2-configure-and-migrate) for setup and type choices.
  `up/1` also validates existing invitation tables.

  This function does not create the token index; use `invitation_index/1` when adding invitations
  after Ithibati's initial migration.
  """
  def invitation_columns(opts) do
    pinned!(opts, "invitation_columns/1")

    identifier = identifier(Config.invitation_schema!())
    inviter? = Keyword.fetch!(opts, :version) >= 4
    named = if inviter?, do: ", invited_by_id", else: ""

    # Include the columns because Ecto logs only the enclosing table operation.
    Logger.info("ithibati: adding #{identifier}, token_hash, expires_at, accepted_at#{named}")

    add(identifier, Keyword.get(opts, :type, :string), null: false)
    add(:token_hash, :binary, binary_options(32))
    add(:expires_at, :utc_datetime_usec, null: false)
    add(:accepted_at, :utc_datetime_usec)

    # Only from version 4. An application's older migration file has to go on producing the table
    # it produced then: a database rebuilt from every migration replays it before the newer one,
    # and a column added to both would collide.
    if inviter?, do: add(:invited_by_id, reference_type(Config.users_key_type()))
  end

  @doc """
  Adds the inviter column to an invitation table that was created before version 4.

  For an application that turned invitations on earlier. A table created with
  `invitation_columns(version: 4)` already has it. The column type follows `users_key_type`,
  which is why this exists rather than a line in the guide: an application that guessed
  `:binary_id` against a `:id` account table would only find out at the first invitation.

      defmodule MyApp.Repo.Migrations.AddInvitedBy do
        use Ecto.Migration

        def change do
          alter table(:invitations) do
            Ithibati.Migration.invitation_inviter_column(version: 4)
          end
        end
      end

  Nullable, and Ithibati writes no foreign key: rows written before the column existed have no
  inviter, and whether one is enforced is the application's to decide about its own table.
  """
  def invitation_inviter_column(opts) do
    pinned!(opts, "invitation_inviter_column/1")

    Keyword.fetch!(opts, :version) >= 4 ||
      raise ArgumentError,
            "invitation_inviter_column/1 adds a version 4 column, got: " <>
              inspect(Keyword.fetch!(opts, :version))

    Logger.info("ithibati: adding invited_by_id")

    add(:invited_by_id, reference_type(Config.users_key_type()))
  end

  @doc """
  Creates or verifies the invitation table's unique `token_hash` index.

  Use this when adding invitations after Ithibati's initial migration has already run.
  `version:` is required, and the configured invitation table must exist.

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

  `up/1` also maintains this index. Both paths create it only when absent and verify its
  uniqueness. If the schema uses `unique_index: false`, the application must create the index;
  this call checks it without creating it.
  """
  def invitation_index(opts) do
    pinned!(opts, "invitation_index/1")

    # Use the same index definition as `up/1` so either migration order is safe.
    %{invitation: Config.invitation_schema!()}
    |> invitation_indexes()
    |> Enum.each(&maintain_index/1)
  end

  # Require a pinned version at every migration entry point.
  defp pinned!(opts, caller) do
    version = Keyword.get(opts, :version)

    version in 1..@current_version//1 ||
      raise ArgumentError,
            "#{caller} needs `version:`, pinned the way `up/1` is — 1 to " <>
              "#{@current_version} in this release, got: #{inspect(version)}"
  end

  defp identifier(schema), do: schema.__ithibati_invitation__(:identifier)

  @doc false
  # Ecto's schema type `:id` may refer to a bigserial account key. Use bigint so foreign keys
  # can hold ids beyond the 32-bit integer limit (2,147,483,647).
  def reference_type(:id), do: :bigint
  def reference_type(other), do: other

  defp settings(opts) do
    schema = Config.user_schema()

    version =
      Keyword.get(opts, :version) ||
        raise(ArgumentError, "version: is required — pin the one this migration was written for")

    from = Keyword.get(opts, :from, 0)

    # Reject empty or unsupported ranges before Ecto can record a migration that did no work.
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

  # Version 4 changed only the invitation table, which the application owns and adds to with
  # `invitation_columns/1` or `invitation_inviter_column/1`. Nothing here moves — but an operator
  # stepping to it writes `up(from: 3, version: 4)` by reflex, and that has to answer.
  defp step(4, _direction, _opts), do: :ok

  defp step(3, :up, _opts) do
    create table(source(SetupCode), primary_key: false) do
      add :id, :integer, primary_key: true
      add :digest, :binary, binary_options(32)
      timestamps(type: :utc_datetime_usec)
    end
  end

  defp step(3, :down, _opts), do: drop_if_exists(table(source(SetupCode)))

  defp step(2, :up, _opts) do
    create table(source(Challenge), primary_key: false) do
      add :token_hash, :binary, Keyword.put(binary_options(32), :primary_key, true)
      add :expires_at, :utc_datetime_usec, null: false
    end

    create index(source(Challenge), [:expires_at])
  end

  defp step(2, :down, _opts), do: drop_if_exists(table(source(Challenge)))

  defp step(1, :up, opts) do
    # MySQL commits DDL statements individually. Resolve application index collisions
    # before creating owned tables so predictable failures leave no partial auth schema.
    if repo().__adapter__() == Ecto.Adapters.MyXQL,
      do: Enum.each(application_indexes(opts), &maintain_index/1)

    holder = references(opts.users_table, type: key_type(), on_delete: :delete_all)

    create table(source(UserKey), primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, holder, null: false
      add :key_id, :binary, binary_options(1023)
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
      add :code_hash, :binary, binary_options(32)
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
      add :token_hash, :binary, binary_options(32)

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

    unless repo().__adapter__() == Ecto.Adapters.MyXQL,
      do: Enum.each(application_indexes(opts), &maintain_index/1)
  end

  defp step(1, :down, opts) do
    for schema <- Enum.reverse(@v1_schemas) do
      if repo().__adapter__() == Ecto.Adapters.MyXQL,
        do: drop_if_exists(table(source(schema))),
        else: drop(table(source(schema)))
    end

    opts |> application_indexes() |> Enum.reverse() |> Enum.each(&drop_index/1)
  end

  # Database indexes enforce uniqueness across concurrent inserts; changesets alone cannot.
  defp application_indexes(opts), do: [account_index(opts) | invitation_indexes(opts)]

  # `unique_index: false` leaves index creation to the application, but still requires
  # a unique index on the identifier alone across the whole table.
  defp account_index(opts) do
    %{
      schema: opts.schema,
      table: opts.users_table,
      column: opts.schema.__ithibati__(:identifier),
      create?: opts.schema.__ithibati__(:unique_index),
      name: opts.schema.__ithibati__(:constraint)
    }
  end

  # Invitation indexes are needed only when an invitation schema is configured.
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

  # Allow both `up/1` and a later invitation migration to request the same index.
  # Postgres checks only the name for `IF NOT EXISTS`, so verify the resulting index too.
  defp maintain_index(index) do
    if index.create?, do: create_index_unless_exists(index)
    confirm_index!(index)
  end

  defp create_index_unless_exists(index) do
    if repo().__adapter__() == Ecto.Adapters.MyXQL do
      flush()

      unless MySQL.index?(repo(), index.table, index_for(index).name),
        do: create(index_for(index))
    else
      create_if_not_exists(index_for(index))
    end
  end

  defp drop_index(%{create?: false}), do: :ok

  defp drop_index(index) do
    if repo().__adapter__() == Ecto.Adapters.MyXQL do
      if MySQL.index?(repo(), index.table, index_for(index).name), do: drop(index_for(index))
    else
      drop_if_exists(index_for(index))
    end
  end

  # `name: nil` is not a missing name. `Ecto.Migration.index/3` fills it in with the one it derives.
  defp index_for(index), do: unique_index(index.table, [index.column], name: index.name)

  # Verify uniqueness on the required column, not merely the existence of a relation name.
  defp confirm_index!(index) do
    # Flush queued DDL before inspecting the catalogue. A matching name may hide a partial
    # or otherwise unsuitable index; Catalogue verifies its actual shape.
    flush()

    match?(
      {_type, true},
      Catalogue.column(repo(), table_ref!(index.table), index.column)
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

  # Check the referenced column before building library tables. A compatible type and
  # a unique index suffice; the column need not be the primary key.
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

  # Check application-owned columns before creating indexes so failures name the missing column.
  defp confirm_indexed_column!(index) do
    oid = table_ref!(index.table)

    Catalogue.column(repo(), oid, index.column) ||
      raise(
        ArgumentError,
        "#{inspect(index.schema)} declares #{qualified(index.table)}.#{index.column}, and the " <>
          "table has no such column. The column is yours to add — in the migration that creates " <>
          "the table, or in one of its own — and this library creates the unique index on it."
      )
  end

  # Validate invitation storage types before the first runtime query. Leave the identifier
  # type open so applications can use `citext` for both accounts and invitations.
  @invitation_columns [
    {:token_hash, :binary},
    {:expires_at, :utc_datetime_usec},
    {:accepted_at, :utc_datetime_usec}
  ]

  defp confirm_invitation_columns!(%{invitation: nil}), do: :ok

  defp confirm_invitation_columns!(%{invitation: schema} = opts) do
    table = source(schema)
    oid = table_ref!(table)

    # From version 4 the schema macro declares the inviter, so every invitation query selects it.
    # Left unchecked, an installation that migrated without adding the column passes here and
    # fails at its first `fetch/1` — which is the failure this whole check exists to come first.
    expected =
      if opts.version >= 4,
        do: @invitation_columns ++ [{:invited_by_id, Config.users_key_type()}],
        else: @invitation_columns

    Enum.each(expected, fn {column, storage_type} ->
      accepted = Catalogue.types(repo(), storage_type)

      case Catalogue.column(repo(), oid, column) do
        nil ->
          raise ArgumentError,
                "#{inspect(schema)} declares #{qualified(table)}.#{column}, and the table has " <>
                  "no such column. `ithibati_invitation/0` declares it and this is one of " <>
                  "them; the table is yours to create."

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
    oid = table_ref!(opts.users_table)

    case Catalogue.key_column(repo(), oid, opts.users_table, account_key_column(opts)) do
      {:ok, _described} -> :ok
      {:error, message} -> raise ArgumentError, message
    end
  end

  # Respect the repository’s `:migration_foreign_key` configuration when checking the target column.
  defp account_key_column(opts) do
    references(opts.users_table, type: reference_type(Config.users_key_type())).column
  end

  defp table_ref!(table) do
    Catalogue.table(repo(), schema_prefix(), table) ||
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

  defp binary_options(size) do
    if repo().__adapter__() == Ecto.Adapters.MyXQL,
      do: [size: size, null: false],
      else: [null: false]
  end

  defp key_type do
    type = reference_type(UserKey.__schema__(:type, :user_id))

    if repo().__adapter__() == Ecto.Adapters.MyXQL and type == :bigint do
      table = source(Config.user_schema())
      column = references(table, type: type).column

      case Catalogue.column(repo(), table_ref!(table), column) do
        {"bigint unsigned", _unique} -> :"bigint unsigned"
        _signed_or_invalid -> :bigint
      end
    else
      type
    end
  end
end
