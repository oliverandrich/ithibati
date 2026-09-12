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

  alias Ecto.Adapters.SQL.Sandbox
  alias Ithibati.RecoveryCode
  alias Ithibati.TestRepo
  alias Ithibati.UserKey
  alias Ithibati.UserToken

  @schema "probe"
  @version 20_990_101_000_000

  defmodule Probe do
    use Ecto.Migration

    # The account table is the consumer's, so the probe brings its own before asking for the rest —
    # and, when the configured schema says it maintains its own unique index, that too. It is playing
    # the application's part in both cases.
    def up do
      create table(:users, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :email, :string
      end

      if name = Ithibati.Config.user_schema().__ithibati__(:constraint) do
        create unique_index(:users, [:email], name: name)
      end

      Ithibati.Migration.up(version: 1)
    end

    def down do
      Ithibati.Migration.down(version: 1)
      drop table(:users)
    end
  end

  # The same, minus the index — so a schema that claims to maintain its own can be driven against a
  # database where it does not exist.
  defmodule ProbeWithoutIndex do
    use Ecto.Migration

    def up do
      create table(:users, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :email, :string
      end

      Ithibati.Migration.up(version: 1)
    end

    def down, do: :ok
  end

  # The sandbox is switched off for this module rather than checked out: `Ecto.Migrator` does its
  # work in a task of its own, which cannot see a connection the test process owns. ExUnit runs every
  # synchronous module after the asynchronous ones have finished, so nothing else is holding a
  # sandboxed connection while this is true.
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

  # The account lookup is `Repo.get_by/3`, which raises on a second match rather than signing anybody
  # in — so this index is a requirement, and requiring something an application has to remember is
  # what this arrangement exists to avoid.
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
  test "and a claimed index that does not exist stops the migration" do
    as_account_schema(Ithibati.OptedOutUser)

    assert_raise ArgumentError, ~r/no index named probe.users_email_uniq/, fn ->
      Ecto.Migrator.up(TestRepo, @version + 1, ProbeWithoutIndex, prefix: @schema, log: false)
    end
  end

  test "the foreign key takes the account table's key type" do
    :ok = migrate(:up)

    assert column_type(UserToken, "user_id") == "uuid"
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

  defp as_account_schema(module) do
    Application.put_env(:ithibati, :user_schema, module)
    on_exit(fn -> Application.put_env(:ithibati, :user_schema, Ithibati.TestUser) end)
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
