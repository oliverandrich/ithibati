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
  alias Ithibati.TestKey
  alias Ithibati.TestRepo
  alias Ithibati.UserKey
  alias Ithibati.UserToken

  @schema "probe"
  @version 20_990_101_000_000

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

    # The key type the library's schemas were compiled with is not movable at runtime, so what a
    # disagreement test moves is the other side: the account table this probe plays the part of.
    defp create_users(:configured) do
      create table(:users, primary_key: false) do
        add :id, TestKey.column_type(), primary_key: true
        add :email, :string
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

    assert column_type(UserToken, "user_id") == TestKey.postgres_type()
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

  defp tables, do: Enum.map([UserKey, RecoveryCode, UserToken], & &1.__schema__(:source))

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

  defp as_invitation_table(shape), do: as_env(:test_invitation_table, shape)

  defp as_no_invitation_schema, do: delete_env(:ithibati, :invitation_schema)

  defp as_env(key, value), do: put_env(:ithibati, key, value)

  defp as_account_schema(module), do: as_env(:user_schema, module)

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
