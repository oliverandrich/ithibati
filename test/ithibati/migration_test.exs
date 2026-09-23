defmodule Ithibati.MigrationTest do
  @moduledoc """
  The migration driven for real, up and back down, through `Ecto.Migrator` — the same path a
  consuming application takes.

  `down/1` is the half nobody runs until somebody needs it, which is the worst moment to discover it
  was never executed. Both run against a Postgres schema of their own, so the suite's tables are
  untouched and the cleanup is a single `DROP SCHEMA`; it also exercises the migrator prefix, which
  a table name interpolated by hand would silently ignore.
  """
  use ExUnit.Case, async: false

  import Ithibati.DataCase, only: [delete_env: 2, put_env: 3]

  alias Ecto.Adapters.SQL.Sandbox
  alias Ithibati.RecoveryCode
  alias Ithibati.Session
  alias Ithibati.TestKey
  alias Ithibati.TestRepo
  alias Ithibati.UserKey

  @schema "probe"
  @version 20_990_101_000_000

  defmodule ChallengeUpgrade do
    use Ecto.Migration
    def up, do: Ithibati.Migration.up(from: 1, version: 2)
    def down, do: Ithibati.Migration.down(from: 1, version: 2)
  end

  defmodule SetupCodeUpgrade do
    use Ecto.Migration
    def up, do: Ithibati.Migration.up(from: 2, version: 3)
    def down, do: Ithibati.Migration.down(from: 2, version: 3)
  end

  defmodule Probe do
    use Ecto.Migration

    # Two variants are raw SQL, because `INCLUDE` columns and a domain type are not expressible
    # through `create table/2` — and they qualify themselves with the migrator's prefix, because raw
    # SQL does not get it the way `table/2` does. Unqualified, they reach the suite's own `users`
    # table in the default schema instead.
    #
    # The account table is the consumer's, so the probe brings its own before asking for the rest —
    # and, when the configured schema says it creates the unique index itself, that too. It is
    # playing the application's part, including the part where an application forgets: setting
    # `:test_app_skips_index` is how a test shows what happens then.
    def up do
      create_users(Application.get_env(:ithibati, :test_account_table, :configured))

      schema = Ithibati.Config.user_schema()

      case {schema.__ithibati__(:unique_index),
            Application.get_env(:ithibati, :test_app_index, :unique)} do
        {true, :collides} -> execute(colliding_index())
        {true, _} -> :ok
        {false, :unique} -> create(unique_index(:users, [:email], name: :users_email_uniq))
        {false, :plain} -> create(index(:users, [:email], name: :users_email_uniq))
        {false, :partial} -> execute(partial_index())
        {false, :none} -> :ok
      end

      create_invitations(Application.get_env(:ithibati, :test_invitation_table, :configured))

      Ithibati.Migration.up(version: 1)
    end

    def down do
      Ithibati.Migration.down(version: 1)
      # The invitation table is left standing on purpose: an application takes its own tables down
      # in its own migration, and what this half has to give back is the index it created on one.
      drop table(:users)
    end

    # The other table a consumer owns, when it invites anybody. `:none` is how a test shows an
    # application that configured an invitation schema and then did not create the table for it.
    defp create_invitations(:configured) do
      create table(:invitations, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :email, :string
        add :token_hash, :binary
        add :expires_at, :utc_datetime_usec
        add :accepted_at, :utc_datetime_usec
      end
    end

    defp create_invitations(:none), do: :ok

    # The columns from the library rather than typed out, which is what a consumer creating the
    # table gets to do. The identifier comes from the schema, so it cannot disagree with it.
    defp create_invitations(:from_the_library) do
      create table(:invitations, primary_key: false) do
        add :id, :binary_id, primary_key: true
        Ithibati.Migration.invitation_columns(version: 1)
      end
    end

    # What an application standing the table up today gets. Version 4 is the first that changed
    # the column set, which is what the pin has always been for.
    defp create_invitations(:from_the_library_v4) do
      create table(:invitations, primary_key: false) do
        add :id, :binary_id, primary_key: true
        Ithibati.Migration.invitation_columns(version: 4)
      end
    end

    # The application that turned invitations on before version 4 and adds the column afterwards,
    # which is every existing installation.
    defp create_invitations(:from_the_library_then_inviter) do
      create_invitations(:from_the_library)

      alter table(:invitations) do
        Ithibati.Migration.invitation_inviter_column(version: 4)
      end
    end

    defp create_invitations(:with_citext) do
      create table(:invitations, primary_key: false) do
        add :id, :binary_id, primary_key: true
        Ithibati.Migration.invitation_columns(version: 1, type: :citext)
      end
    end

    # The consumer who turned invitations on later has both the table and the index in a
    # migration of their own, and a rebuilt database replays that before `up/1`.
    defp create_invitations(:from_the_library_with_index) do
      create_invitations(:from_the_library)
      Ithibati.Migration.invitation_index(version: 1)
    end

    # The columns are there and one of them is the wrong type — the shape that migrates green
    # today and fails at the first invitation.
    defp create_invitations(:wrong_types) do
      create table(:invitations, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :email, :string
        add :token_hash, :string
        add :expires_at, :utc_datetime_usec
        add :accepted_at, :utc_datetime_usec
      end
    end

    defp create_invitations(:no_expiry) do
      create table(:invitations, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :email, :string
        add :token_hash, :binary
        add :accepted_at, :utc_datetime_usec
      end
    end

    defp create_invitations(:no_token_hash) do
      create table(:invitations, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :email, :string
        add :expires_at, :utc_datetime_usec
        add :accepted_at, :utc_datetime_usec
      end
    end

    # The key type the library's schemas were compiled with is not movable at runtime, so what a
    # disagreement test moves is the other side: the account table this probe plays the part of.
    defp create_users(:configured) do
      create table(:users, primary_key: false) do
        add :id, TestKey.column_type(), primary_key: true
        add :email, :string
      end
    end

    defp create_users(:no_identifier) do
      create table(:users, primary_key: false) do
        add :id, TestKey.column_type(), primary_key: true
      end
    end

    # The *other* type this library supports, rather than something no consumer would ever write:
    # a `bigserial` account table under a `binary_id` configuration is the mistake people make, and
    # it is the one that goes unnoticed if the library's list of acceptable Postgres types ever
    # gains an entry it should not have.
    defp create_users(:wrong_type) do
      create table(:users, primary_key: false) do
        add :id, TestKey.other_column_type(), primary_key: true
        add :email, :string
      end
    end

    defp create_users(:composite) do
      create table(:users, primary_key: false) do
        add :tenant, :string, primary_key: true
        add :id, TestKey.column_type(), primary_key: true
        add :email, :string
      end
    end

    # `INCLUDE` columns sit in `indkey` beside the key ones, so an index check that counted the
    # whole vector would not recognise this as covering `id` alone.
    defp create_users(:include) do
      execute(
        "CREATE TABLE #{prefix()}.users (id #{TestKey.postgres_type()}, email text, PRIMARY KEY (id) INCLUDE (email))"
      )
    end

    # A domain is a type of its own by name; what a foreign key compares against is what it is built
    # on. It is created inside the probe's schema so that dropping that schema takes it along.
    defp create_users(:domain) do
      execute("CREATE DOMAIN #{prefix()}.account_id AS #{TestKey.postgres_type()}")

      execute(
        "CREATE TABLE #{prefix()}.users (id #{prefix()}.account_id PRIMARY KEY, email text)"
      )
    end

    # Legal, and what the refusal for a bare composite key advises: Postgres lets a foreign key
    # point at any column with a unique index on it, primary key or not.
    defp create_users(:composite_unique) do
      create_users(:composite)
      create unique_index(:users, [:id])
    end

    # A unique index the table does have, on a column nobody references. Without it, a check that
    # merely asks "has this table any single-column unique index" looks exactly like one that asks
    # about the right column.
    defp create_users(:unique_elsewhere) do
      create_users(:composite)
      create unique_index(:users, [:email])
    end

    # A single-column primary key of the right type that the foreign key still cannot point at,
    # because it is not the column the foreign key names.
    defp create_users(:renamed_key) do
      create table(:users, primary_key: false) do
        add :uid, TestKey.column_type(), primary_key: true
        add :email, :string
      end
    end

    defp create_users(:none), do: :ok

    # Not expressible through `unique_index/2` with a `where:` that Ecto renders the same way, and
    # written out here so the `WHERE` is unmistakably part of the index rather than of the migration.
    defp partial_index do
      "CREATE UNIQUE INDEX users_email_uniq ON #{prefix()}.users (email) WHERE email IS NOT NULL"
    end

    # The same shape under the name `create unique_index(:users, [:email])` derives, which is what
    # `create_if_not_exists` compares against.
    defp colliding_index do
      "CREATE UNIQUE INDEX users_email_index ON #{prefix()}.users (email) WHERE email IS NOT NULL"
    end
  end

  # A second migration of the consumer's own, which is the shape the documentation prescribes for
  # turning invitations on later. At module level rather than inside the helper: two tests run it
  # now, and a `defmodule` in a function body redefines the module on the second call.
  defmodule LaterInvitations do
    use Ecto.Migration

    def change, do: Ithibati.Migration.invitation_index(version: 1)
  end

  defmodule ToVersionFour do
    use Ecto.Migration

    def up, do: Ithibati.Migration.up(from: 3, version: 4)
    def down, do: Ithibati.Migration.down(from: 3, version: 4)
  end

  # The sandbox is switched off for this module rather than checked out: `Ecto.Migrator` does its
  # work in a task of its own, which cannot see a connection the test process owns. ExUnit runs every
  # synchronous module after the asynchronous ones have finished, so nothing else is holding a
  # sandboxed connection while this is true.
  #
  # Not `Ithibati.RaceCase`, which switches it off for the other reason: nothing here races, so
  # there is no pool to measure against and nothing for that template to hold.
  setup_all do
    Sandbox.mode(TestRepo, :auto)
    reset_schema()

    on_exit(fn ->
      query("DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
      Sandbox.mode(TestRepo, :manual)
    end)
  end

  setup do
    on_exit(&reset_schema/0)
  end

  # The probe creates `users` and calls `up/1` in one migration, which is a shape a consumer is
  # allowed to write — so this reaches the key-type check through a queue that has to be flushed
  # before the account table is there to ask about at all.
  test "up builds a table for every schema, under the migrator's prefix" do
    assert missing() == tables()

    assert :ok = migrate(:up)

    assert missing() == []
  end

  test "version 2 upgrades and rolls back without removing version 1 tables" do
    :ok = migrate(:up)

    assert :ok =
             Ecto.Migrator.up(TestRepo, @version + 1, ChallengeUpgrade,
               prefix: @schema,
               log: false
             )

    table = Ithibati.Catalogue.table(TestRepo, @schema, "ithibati_challenges")
    assert is_integer(table)
    assert {"bytea", true} = Ithibati.Catalogue.column(TestRepo, table, :token_hash)

    assert :ok =
             Ecto.Migrator.down(TestRepo, @version + 1, ChallengeUpgrade,
               prefix: @schema,
               log: false
             )

    assert Ithibati.Catalogue.table(TestRepo, @schema, "ithibati_challenges") == nil
    assert missing() == []
  end

  test "version 3 adds and rolls back operator-code storage independently" do
    :ok = migrate(:up)

    assert :ok =
             Ecto.Migrator.up(TestRepo, @version + 1, ChallengeUpgrade,
               prefix: @schema,
               log: false
             )

    assert :ok =
             Ecto.Migrator.up(TestRepo, @version + 2, SetupCodeUpgrade,
               prefix: @schema,
               log: false
             )

    table = Ithibati.Catalogue.table(TestRepo, @schema, "ithibati_setup_codes")
    assert is_integer(table)
    assert {"bytea", false} = Ithibati.Catalogue.column(TestRepo, table, :digest)

    assert :ok =
             Ecto.Migrator.down(TestRepo, @version + 2, SetupCodeUpgrade,
               prefix: @schema,
               log: false
             )

    assert Ithibati.Catalogue.table(TestRepo, @schema, "ithibati_setup_codes") == nil
    assert Ithibati.Catalogue.table(TestRepo, @schema, "ithibati_challenges")
  end

  test "down removes every table it built" do
    :ok = migrate(:up)

    assert :ok = migrate(:down)

    assert missing() == tables()
  end

  test "the unique index its own lookup depends on is one of the things it creates" do
    :ok = migrate(:up)

    assert "users_email_index" in indexes("users")
  end

  test "and it is not, when the application said it maintains its own" do
    as_account_schema(Ithibati.OptedOutUser)

    :ok = migrate(:up)

    # Exactly the application's own, and no second one beside it. A redundant unique index breaks
    # nothing and would therefore never be noticed, which is why this reads the catalogue rather than
    # a changeset.
    assert Enum.reject(indexes("users"), &String.ends_with?(&1, "_pkey")) == ["users_email_uniq"]
  end

  # Saying "I maintain my own" and not having one is the same failure the creation exists to prevent,
  # so the claim is checked rather than believed.
  test "and an application that says so and then does not have one is stopped" do
    as_account_schema(Ithibati.OptedOutUser)
    as_application_index(:none)

    assert_raise ArgumentError, ~r/unique index on users\.email — there is none/, fn ->
      migrate(:up)
    end

    # Stopped, not merely complained about: the refusal comes after `flush()`, so the tables were
    # already written when it fired, and only the surrounding transaction takes them back.
    assert missing() == tables()
  end

  # Asked of `pg_index` rather than of the name: a relation of the right name that is not a unique
  # index over that column is exactly what a name check would wave through.
  test "and an index that is not unique does not count as one" do
    as_account_schema(Ithibati.OptedOutUser)
    as_application_index(:plain)

    assert_raise ArgumentError, ~r/unique index on users\.email — there is none/, fn ->
      migrate(:up)
    end
  end

  # A partial unique index is the shape a consumer with soft-deleted accounts writes, and it permits
  # exactly what the check exists to forbid: two rows sharing the identifier, one of them filtered
  # out of the index.
  test "and a unique index that covers only some of the rows does not count either" do
    as_account_schema(Ithibati.OptedOutUser)
    as_application_index(:partial)

    assert_raise ArgumentError, ~r/unique index on users\.email — there is none/, fn ->
      migrate(:up)
    end
  end

  # `create_if_not_exists` matches on the index name and nothing else, so an index of the
  # application's under the name Ecto derives makes the create a silent no-op. The migration then
  # succeeded and the account lookup found two rows at the next sign-in.
  test "and an index of the application's under the name this library derives is not taken for ours" do
    as_application_index(:collides)

    assert_raise ArgumentError, ~r/users_email_index.*matches on that name alone/s, fn ->
      migrate(:up)
    end
  end

  test "the index it creates carries the name the application asked for" do
    as_account_schema(Ithibati.NamedIndexUser)

    :ok = migrate(:up)

    assert "users_email_house" in indexes("users")
  end

  describe "the invitation table an application configures" do
    test "gets the unique index the library's lookup depends on" do
      :ok = migrate(:up)

      assert "invitations_token_hash_index" in indexes("invitations")
    end

    test "and loses it again on the way down, without the table going with it" do
      :ok = migrate(:up)

      assert :ok = migrate(:down)

      assert Enum.reject(indexes("invitations"), &String.ends_with?(&1, "_pkey")) == []
    end

    # An invitation schema in the configuration and no table to go with it is the same shape of
    # mistake as a missing account table, and gets the same refusal rather than a Postgres error.
    test "and a configured schema with no table behind it is refused" do
      as_invitation_table(:none)

      assert_raise ArgumentError, ~r/there is no table probe\.invitations/, fn -> migrate(:up) end
    end

    # Configuring none is the ordinary case for an application that never invites anybody, and the
    # migration has nothing to do about it.
    test "and an application that configures none is asked for nothing" do
      as_no_invitation_schema()
      as_invitation_table(:none)

      assert :ok = migrate(:up)
    end
  end

  test "the foreign key takes the account table's key type" do
    :ok = migrate(:up)

    assert column_type(Session, "user_id") == TestKey.postgres_type()
  end

  # The column is the application's to add and the index on it is this library's to create, which
  # is a line a reader has to be told about — so the migration says it rather than letting
  # Postgres refuse an index on a column nobody mentioned.
  describe "a table missing the column this library indexes" do
    test "an account table with no identifier column is refused" do
      as_account_table(:no_identifier)

      assert_raise ArgumentError,
                   ~r/#{inspect(TestUser)} declares .*users\.email, and the table has no such column.*yours to add/s,
                   fn -> migrate(:up) end

      assert missing() == tables()
    end

    test "a token_hash of the wrong type is refused, naming both types" do
      as_invitation_table(:wrong_types)

      assert_raise ArgumentError,
                   ~r/invitations\.token_hash is character varying.*reads it as bytea/s,
                   fn ->
                     migrate(:up)
                   end

      assert missing() == tables()
    end

    test "a column the schema declares and the table does not have is refused" do
      as_invitation_table(:no_expiry)

      assert_raise ArgumentError,
                   ~r/invitations\.expires_at, and the table has no such column/s,
                   fn ->
                     migrate(:up)
                   end

      assert missing() == tables()
    end

    test "an invitation table with no token_hash is refused" do
      as_invitation_table(:no_token_hash)

      assert_raise ArgumentError,
                   ~r/#{inspect(TestInvitation)} declares .*invitations\.token_hash, and the table has no such column/s,
                   fn -> migrate(:up) end

      assert missing() == tables()
    end
  end

  # The counterpart to `ithibati_invitation/0`: the schema declares the fields, this adds the
  # columns behind them, and neither can drift from the other because both read the identifier
  # off the same schema.
  # Turning invitations on after `up/1` has already run is the ordinary case, not an edge one —
  # and `up/1` cannot run again to create the index, so the consumer's own migration has to.
  describe "invitation_index/1" do
    test "creates the index this library's migration would have" do
      as_invitation_table(:from_the_library)
      migrate(:up)

      query("DROP INDEX #{@schema}.invitations_token_hash_index", [])
      assert token_hash_indexes() == []

      run_index_migration()

      assert token_hash_indexes() != []
    end

    test "refuses a version this release does not know" do
      assert_raise ArgumentError, ~r/version/, fn ->
        Ithibati.Migration.invitation_index(version: 99)
      end
    end

    # The order the two can arrive in is not ours to control. This is the one that can collide:
    # the consumer's migration made the index, and `up/1` then runs over a database that has it.
    test "does not collide with the index up/1 creates" do
      as_invitation_table(:from_the_library_with_index)

      assert :ok = migrate(:up)
      assert length(token_hash_indexes()) == 1
    end

    # The same name-only match `up/1` is now held to. This is the more exposed of the two paths:
    # it is called from the consumer's own migration, in the "I turned invitations on later"
    # case, against a table they have been maintaining indexes on themselves.
    test "and an index of the application's under the same name is not taken for ours" do
      as_invitation_table(:from_the_library)
      migrate(:up)

      query("DROP INDEX #{@schema}.invitations_token_hash_index", [])

      query(
        "CREATE UNIQUE INDEX invitations_token_hash_index ON #{@schema}.invitations " <>
          "(token_hash) WHERE accepted_at IS NULL",
        []
      )

      assert_raise ArgumentError, ~r/matches on that name alone/, fn -> run_index_migration() end
    end
  end

  # An operator upgrading writes this by reflex. Version 4 changed nothing in this library's own
  # tables, but answering a reflex with a FunctionClauseError is not an answer.
  test "stepping to version four builds nothing here and succeeds anyway" do
    as_invitation_table(:from_the_library_v4)
    migrate(:up)

    assert :ok =
             Ecto.Migrator.up(TestRepo, @version + 2, ToVersionFour, prefix: @schema, log: false)

    assert missing() == []

    assert :ok =
             Ecto.Migrator.down(TestRepo, @version + 2, ToVersionFour,
               prefix: @schema,
               log: false
             )

    assert missing() == []
  end

  # The check exists so that a missing column is a word at migration time rather than a Postgres
  # error at the first invitation. Version 4 added one, and leaving it out of the check is how an
  # upgrade goes green and the application falls over afterwards.
  test "and refuses a version four migration against a table without the inviter" do
    as_invitation_table(:from_the_library)
    migrate(:up)

    # The refusal has to say what to do. "The table is yours to create" is the right sentence for a
    # column that was always part of the shape and the wrong one here: the table is right, it
    # predates version 4, and one helper adds what it is missing. The order matters too, and only
    # in one direction — `up/1` flushes before it looks, so an `alter` queued above it has already
    # run, and the same `alter` written below it has not.
    message =
      assert_raise ArgumentError, fn ->
        Ecto.Migrator.up(TestRepo, @version + 3, ToVersionFour, prefix: @schema, log: false)
      end

    assert message.message =~ "invited_by_id"
    assert message.message =~ "invitation_inviter_column"
    assert message.message =~ "before the call to `up/1`"
    refute message.message =~ "the table is yours to create"
  end

  describe "invitation_columns/1" do
    test "builds a table the migration then accepts" do
      as_invitation_table(:from_the_library)

      assert :ok = migrate(:up)
      assert missing() == []
    end

    # An old migration file has to go on meaning what it meant: a database rebuilt from every
    # migration replays it and then the newer one, and a column added to both would collide.
    test "adds the inviter from version four, and not before it" do
      as_invitation_table(:from_the_library)
      migrate(:up)

      refute "invited_by_id" in invitation_column_names()

      reset_schema()
      as_invitation_table(:from_the_library_v4)
      migrate(:up)

      assert "invited_by_id" in invitation_column_names()
    end

    test "and an existing table gets it from invitation_inviter_column/1" do
      as_invitation_table(:from_the_library_then_inviter)

      assert :ok = migrate(:up)
      assert missing() == []
      assert "invited_by_id" in invitation_column_names()
    end

    test "names the identifier the schema declares and defaults to string" do
      as_invitation_table(:from_the_library)
      migrate(:up)

      assert %{rows: [["character varying(255)"]]} =
               query(
                 """
                 SELECT format_type(a.atttypid, a.atttypmod)
                 FROM pg_attribute a
                 WHERE a.attrelid = to_regclass($1)::oid AND a.attname = $2 AND a.attnum > 0
                 """,
                 ["#{@schema}.invitations", "email"]
               )
    end

    test "uses citext for the identifier and passes the migration checks" do
      %{rows: [[installed?]]} =
        query("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'citext')", [])

      unless installed? do
        query("CREATE EXTENSION citext WITH SCHEMA public", [])

        on_exit(fn ->
          # Remove our dependent columns first; avoid CASCADE deleting unrelated objects.
          reset_schema()
          query("DROP EXTENSION citext", [])
        end)
      end

      as_invitation_table(:with_citext)
      assert :ok = migrate(:up)
      assert missing() == []

      assert %{rows: [["citext", "NO"]]} =
               query(
                 """
                 SELECT udt_name, is_nullable FROM information_schema.columns
                 WHERE table_schema = $1 AND table_name = 'invitations' AND column_name = 'email'
                 """,
                 [@schema]
               )

      # Check the generated column's comparison behavior, not only its catalogue type name.
      assert %{rows: [[true]]} =
               query(
                 """
                 WITH inserted AS (
                   INSERT INTO #{@schema}.invitations (id, email, token_hash, expires_at)
                   VALUES ('00000000-0000-0000-0000-000000000001', 'Mixed@Example.com',
                           decode('01', 'hex'), now())
                   RETURNING email
                 )
                 SELECT email = 'mixed@example.com' FROM inserted
                 """,
                 []
               )
    end

    test "refuses a version this release does not know" do
      assert_raise ArgumentError, ~r/version/, fn ->
        Ithibati.Migration.invitation_columns(version: 99)
      end
    end

    test "refuses to be called without one" do
      assert_raise ArgumentError, ~r/version/, fn ->
        Ithibati.Migration.invitation_columns([])
      end
    end
  end

  describe "an account table this library cannot point a foreign key at" do
    # The error this replaces comes from inside `references/2` and names two Postgres columns,
    # neither this library nor the setting that caused it.
    test "a column of a type the foreign key cannot compare against is refused" do
      as_account_table(:wrong_type)

      assert_raise ArgumentError,
                   ~r/users_key_type:.*users\.id is #{TestKey.other_postgres_type()}/s,
                   fn -> migrate(:up) end

      assert missing() == tables()
    end

    # Not "the primary key is composite": what Postgres wants is a unique index on the column being
    # referenced, and saying so is what makes the advice in the message actionable.
    test "a column with no unique index of its own is refused" do
      as_account_table(:composite)

      assert_raise ArgumentError, ~r/users\.id carries no unique index/, fn -> migrate(:up) end

      assert missing() == tables()
    end

    test "and a unique index on some other column is not a substitute" do
      as_account_table(:unique_elsewhere)

      assert_raise ArgumentError, ~r/users\.id carries no unique index/, fn -> migrate(:up) end
    end

    test "a table without the column the foreign key names is refused" do
      as_account_table(:renamed_key)

      assert_raise ArgumentError, ~r/users has no column id/, fn -> migrate(:up) end

      assert missing() == tables()
    end

    test "no account table at all is refused before anything is built" do
      as_account_table(:none)

      # Qualified with the migrator's prefix: an unqualified name sends the reader looking in
      # `public`, which is the one schema the table is certainly not in.
      assert_raise ArgumentError, ~r/there is no table probe\.users/, fn -> migrate(:up) end

      assert missing() == tables()
    end
  end

  describe "an account table the check must not refuse" do
    test "a single-column primary key with INCLUDE columns beside it" do
      as_account_table(:include)

      assert :ok = migrate(:up)
    end

    test "a primary key whose type is a domain over one this library can reference" do
      as_account_table(:domain)

      assert :ok = migrate(:up)
    end

    # The arrangement the refusal above tells a consumer to make. Refusing it as well would be
    # advice the library does not accept.
    test "a composite primary key with a unique index on the referenced column beside it" do
      as_account_table(:composite_unique)

      assert :ok = migrate(:up)
    end
  end

  defp migrate(:up), do: Ecto.Migrator.up(TestRepo, @version, Probe, prefix: @schema, log: false)

  defp migrate(:down),
    do: Ecto.Migrator.down(TestRepo, @version, Probe, prefix: @schema, log: false)

  defp tables, do: Enum.map([UserKey, RecoveryCode, Session], & &1.__schema__(:source))

  # One round trip, and it answers *which* rather than merely whether.
  defp missing do
    %{rows: rows} =
      query(
        "SELECT name FROM unnest($1::text[]) name WHERE to_regclass($2 || '.' || name) IS NULL",
        [tables(), @schema]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  defp column_type(schema, column) do
    %{rows: [[type]]} =
      query(
        "SELECT data_type FROM information_schema.columns
         WHERE table_schema = $1 AND table_name = $2 AND column_name = $3",
        [@schema, schema.__schema__(:source), column]
      )

    type
  end

  defp as_account_table(shape), do: as_env(:test_account_table, shape)

  defp as_application_index(kind), do: as_env(:test_app_index, kind)

  defp invitation_column_names do
    %{rows: rows} =
      query(
        """
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = 'invitations'
        """,
        [@schema]
      )

    List.flatten(rows)
  end

  defp as_invitation_table(shape), do: as_env(:test_invitation_table, shape)

  defp as_no_invitation_schema, do: delete_env(:ithibati, :invitation_schema)

  defp as_env(key, value), do: put_env(:ithibati, key, value)

  defp as_account_schema(module), do: as_env(:user_schema, module)

  defp run_index_migration do
    Ecto.Migrator.up(TestRepo, @version + 1, LaterInvitations, prefix: @schema, log: false)
  end

  defp token_hash_indexes do
    "invitations"
    |> indexes()
    |> Enum.filter(&String.contains?(&1, "token_hash"))
  end

  defp indexes(table) do
    %{rows: rows} =
      query("SELECT indexname FROM pg_indexes WHERE schemaname = $1 AND tablename = $2", [
        @schema,
        table
      ])

    rows |> List.flatten() |> Enum.sort()
  end

  defp query(sql, params), do: TestRepo.query!(sql, params, log: false)

  # Before as well as after: a run killed between the migration and the cleanup would otherwise leave
  # every later run failing at the migration rather than at the leftovers.
  defp reset_schema do
    query("DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
    query("CREATE SCHEMA #{@schema}", [])
  end
end
