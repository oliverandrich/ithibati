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

  The foreign key's type is not an option either: `config :ithibati, users_key_type:` is compiled
  into the schemas, and this migration reads it back out of one of them. An application can still
  configure a type its own account table does not have — so before anything is built, the column
  these foreign keys will point at is asked what it is, and a disagreement is refused rather than
  half-applied.
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
    confirm_tables!(opts)
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

    # `redeem/2` spends a code with a single statement and reads its answer from the row count, so a
    # second row with the same digest would spend both and answer neither.
    create unique_index(source(RecoveryCode), [:code_hash])
    create index(source(RecoveryCode), [:user_id])

    create table(source(UserToken), primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, holder, null: false
      add :token_hash, :binary, null: false
      add :context, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(source(UserToken), [:token_hash])
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

    Enum.each(application_indexes(opts), &maintain_index/1)
  end

  defp step(1, :down, opts) do
    for schema <- Enum.reverse(@v1_schemas), do: drop(table(source(schema)))

    opts |> application_indexes() |> Enum.reverse() |> Enum.each(&drop_index/1)
  end

  # Every index this library maintains on a table it does not own, as a list, so that a third such
  # table is an entry rather than another pair of functions. Why it maintains them at all:
  # `docs/design.md`, decision 2.
  defp application_indexes(opts), do: [account_index(opts) | invitation_indexes(opts)]

  # The account lookup this library performs is `Repo.get_by/3`, which raises on a second match
  # rather than signing anybody in — so the unique index on the identifier is not decoration, and
  # leaving it to an application to remember would be requiring something and then hoping.
  #
  # `unique_index: false` is how an application says it maintains its own — a partial, expression or
  # composite index this library has no business guessing at — and then the index is checked instead.
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

  defp maintain_index(index) do
    if index.create?, do: create(index_for(index)), else: confirm_index!(index)
  end

  defp drop_index(index) do
    # `drop_if_exists`, because the decision is read from configuration that can change between the
    # two runs.
    if index.create?, do: drop_if_exists(index_for(index))
  end

  # `name: nil` is not a missing name — `Ecto.Migration.index/3` fills it in with the one it derives.
  defp index_for(index), do: unique_index(index.table, [index.column], name: index.name)

  # Asked of `pg_index` rather than of the name: `to_regclass` answers for any relation that happens
  # to be called that — a table, a view, a non-unique index, an index on another column would all
  # pass. What the account lookup needs is a unique index over exactly this column.
  defp confirm_index!(index) do
    # `create/1` only queues; the query below runs at once, so flush first or it cannot see an index
    # the calling migration has just asked for. `confirm_tables!/1` has already flushed by the time
    # this runs, and this one stays anyway: a check that depends on a flush somewhere else is a check
    # that breaks when two lines are swapped, and flushing an empty queue costs nothing.
    #
    # `indpred IS NULL` rules out a partial index, and it is the one a consumer is most likely to
    # have: `UNIQUE (email) WHERE deleted_at IS NULL` looks like a unique index and lets two rows
    # share the value, which is the `Ecto.MultipleResultsError` this check exists to prevent. Same
    # condition `referenced_column/2` puts on the account key, for the same reason.
    flush()

    %{rows: rows} =
      repo().query!(
        """
        SELECT 1
        FROM pg_index x
        JOIN pg_attribute a ON a.attrelid = x.indrelid AND a.attnum = x.indkey[0]
        WHERE x.indisunique AND x.indnkeyatts = 1 AND x.indpred IS NULL
          AND x.indrelid = $1::oid AND a.attname = $2
        LIMIT 1
        """,
        [table_oid!(index.table), to_string(index.column)],
        log: false
      )

    rows != [] ||
      raise(
        ArgumentError,
        "#{inspect(index.schema)} passes `unique_index: false`, so this library expects the " <>
          "application to maintain a unique index on #{index.table}.#{index.column} — there is " <>
          "none. Create it, or drop the option and let this library create one."
      )
  end

  # What Postgres calls the column a foreign key of this type can point at. An `:id` account table
  # is `bigserial` by default but `serial` is a legal choice, and Postgres references across the
  # integer widths happily — they share an operator family.
  @key_columns %{binary_id: ["uuid"], bigint: ["smallint", "integer", "bigint"]}

  # What `references/2` will demand of the account table, asked before anything is built rather than
  # discovered from inside it: the column it points at has to exist, be a type this foreign key can
  # compare against, and carry a unique index. A unique index is what Postgres requires of any
  # referenced column — not a primary key — so a composite primary key with `UNIQUE (id)` beside it
  # is a legal account table, and this is why it passes. `docs/design.md` decision 2 says why the
  # library verifies this at all.
  defp confirm_tables!(opts) do
    # Nothing to confirm while tearing down, and `flush/0` refuses to run in that direction at all —
    # a consumer whose `change/0` calls `up/1` would otherwise fail its rollback here.
    if direction() == :up do
      # `create/1` only queues, and an application is allowed to create its tables and call `up/1`
      # in one migration.
      flush()

      # Every table this library reads without owning. Asked for first, so that a missing one is a
      # word about the setting that named it rather than a Postgres error about a relation nobody
      # mentioned.
      Enum.each(application_indexes(opts), &table_oid!(&1.table))

      confirm_account_key!(opts)
    end
  end

  defp confirm_account_key!(opts) do
    column = account_key_column(opts)

    case referenced_column(table_oid!(opts.users_table), column) do
      nil -> refuse_missing_column!(column, opts)
      [type, unique?] -> confirm_key!(type, unique?, column, opts)
    end
  end

  # Read off the reference rather than assumed: Ecto points a foreign key at `:id` unless the repo
  # moves it with `:migration_foreign_key`, and a check that guessed would pass tables the migration
  # then fails on.
  defp account_key_column(opts) do
    references(opts.users_table, type: key_type()).column
  end

  # Resolved the way Ecto resolves the `REFERENCES` clause it is about to emit: qualified when the
  # migrator has a prefix, through the search path when it has not. Quoted by Postgres rather than
  # by us, so a table whose name is not lower case answers for itself instead of being downcased
  # into a different one.
  defp table_oid!(table) do
    %{rows: [[oid]]} =
      repo().query!(
        "SELECT to_regclass(coalesce(quote_ident($2) || '.', '') || quote_ident($1))::oid",
        [table, schema_prefix()],
        log: false
      )

    oid ||
      raise(
        ArgumentError,
        "there is no table #{qualified(table)} — this library's migration reads and references " <>
          "the tables your application owns, so it runs after the migrations that create them."
      )
  end

  # A domain resolves to what it is built on, because that is what the foreign key compares against.
  # The index has to cover that column and nothing else (`indnkeyatts`, which counts key columns
  # only, so `PRIMARY KEY (id) INCLUDE (email)` still qualifies) and must not be partial, which
  # Postgres refuses as a reference target.
  defp referenced_column(oid, column) do
    %{rows: rows} =
      repo().query!(
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

    List.first(rows)
  end

  defp confirm_key!(type, unique?, column, opts) do
    type in Map.fetch!(@key_columns, key_type()) ||
      raise(
        ArgumentError,
        "config :ithibati, users_key_type: #{inspect(Config.users_key_type())} — but " <>
          "#{opts.users_table}.#{column} is #{type}. Configure the type that column has, or give " <>
          "it the type you configured; a foreign key cannot bridge the two."
      )

    unique? ||
      raise(
        ArgumentError,
        "#{opts.users_table}.#{column} carries no unique index, and Postgres will not let a " <>
          "foreign key point at a column that does not. A primary key, a unique constraint or a " <>
          "unique index on that column will do — beside a composite primary key if you have one."
      )
  end

  defp refuse_missing_column!(column, opts) do
    raise ArgumentError,
          "#{opts.users_table} has no column #{column}, which is where this library's foreign " <>
            "keys point. Ecto takes that name from the repo's `:migration_foreign_key` setting " <>
            "and defaults it to `id`."
  end

  defp qualified(table) do
    case schema_prefix() do
      nil -> table
      prefix -> "#{prefix}.#{table}"
    end
  end

  # The migrator's prefix, or the one the repo migrates into by default — which is what
  # `Ecto.Migration` itself falls back to when it creates a table.
  defp schema_prefix, do: prefix() || repo().config()[:migration_default_prefix]

  defp source(schema), do: schema.__schema__(:source)

  defp key_type, do: reference_type(UserKey.__schema__(:type, :user_id))
end
