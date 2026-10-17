if Application.get_env(:ithibati, :probe_adapter) in [Ecto.Adapters.SQLite3, Ecto.Adapters.MyXQL] do
  defmodule Ithibati.AdapterOpenInvitationsTest do
    use ExUnit.Case, async: false

    alias Ithibati.AdapterIdentityRepo, as: Repo
    alias Ithibati.Catalogue

    @sqlite? Application.compile_env!(:ithibati, :probe_adapter) == Ecto.Adapters.SQLite3

    # Another table of the application's that points at the invitations. SQLite rebuilds the
    # invitation table, and a cascade fired by that rebuild would delete these rows.
    defmodule Grants do
      use Ecto.Migration

      def change do
        create table(:app_grants, primary_key: false) do
          add :id, :binary_id, primary_key: true

          add :invitation_id,
              references(:app_invitations, type: :binary_id, on_delete: :delete_all)
        end
      end
    end

    defmodule OpenInTransaction do
      use Ecto.Migration
      def up, do: Ithibati.Migration.open_invitations(version: 5)
      def down, do: Ithibati.Migration.open_invitations(version: 5)
    end

    defmodule OpenOutsideTransaction do
      use Ecto.Migration
      @disable_ddl_transaction true
      def up, do: Ithibati.Migration.open_invitations(version: 5)
      def down, do: Ithibati.Migration.open_invitations(version: 5)
    end

    setup do
      for {key, value} <- [
            repo: Repo,
            user_schema: Ithibati.AdapterUser,
            invitation_schema: Ithibati.AdapterInvitation
          ] do
        previous = Application.fetch_env(:ithibati, key)
        Application.put_env(:ithibati, key, value)

        on_exit(fn ->
          case previous do
            {:ok, old} -> Application.put_env(:ithibati, key, old)
            :error -> Application.delete_env(:ithibati, key)
          end
        end)
      end

      for {version, migration} <- [
            {10, Ithibati.AdapterApplicationMigration},
            {11, Ithibati.AdapterLibraryMigration},
            {14, Ithibati.AdapterChallengeMigration},
            {15, Ithibati.AdapterSetupCodeMigration},
            {16, Ithibati.AdapterInviterMigration}
          ],
          do: Ecto.Migrator.up(Repo, version, migration, log: false)

      # Every test starts from a version 4 table and leaves version 5 behind, as the identity
      # tests expect it.
      Ecto.Migrator.down(Repo, 17, Ithibati.AdapterOpenInvitationMigration, log: false)
      Repo.query!("DELETE FROM app_invitations")

      on_exit(fn ->
        Ecto.Migrator.up(Repo, 17, Ithibati.AdapterOpenInvitationMigration, log: false)
      end)

      :ok
    end

    test "an existing table opens with its rows and indexes, and closes again" do
      insert_invitation("kept@example.test")
      table = Catalogue.table(Repo, nil, "app_invitations")
      refute Catalogue.nullable?(Repo, table, :email)

      assert :ok = Ecto.Migrator.up(Repo, 17, Ithibati.AdapterOpenInvitationMigration, log: false)

      assert Catalogue.nullable?(Repo, table, :email)
      assert {"text", false} = Catalogue.column(Repo, table, :note)
      assert {_type, true} = Catalogue.column(Repo, table, :token_hash)
      assert Repo.query!("SELECT email FROM app_invitations").rows == [["kept@example.test"]]

      Repo.query!("DELETE FROM app_invitations")

      assert :ok =
               Ecto.Migrator.down(Repo, 17, Ithibati.AdapterOpenInvitationMigration, log: false)

      refute Catalogue.nullable?(Repo, table, :email)
      refute Catalogue.column(Repo, table, :note)
    end

    test "a table that is already open stays as it is" do
      assert :ok = Ecto.Migrator.up(Repo, 17, Ithibati.AdapterOpenInvitationMigration, log: false)

      try do
        assert :ok = Ecto.Migrator.up(Repo, 31, OpenInTransaction, log: false)
        assert Catalogue.nullable?(Repo, Catalogue.table(Repo, nil, "app_invitations"), :email)
      after
        Ecto.Migrator.down(Repo, 31, OpenInTransaction, log: false)
        Ecto.Migrator.down(Repo, 17, Ithibati.AdapterOpenInvitationMigration, log: false)
      end
    end

    if @sqlite? do
      test "a SQLite rebuild survives a view that names the table" do
        Repo.query!("CREATE VIEW app_pending AS SELECT email FROM app_invitations")

        try do
          assert :ok =
                   Ecto.Migrator.up(Repo, 17, Ithibati.AdapterOpenInvitationMigration, log: false)

          assert Repo.query!("SELECT * FROM app_pending").rows == []
        after
          Repo.query!("DROP VIEW IF EXISTS app_pending")
        end
      end

      test "a SQLite table others reference needs the migration outside a transaction" do
        Ecto.Migrator.up(Repo, 30, Grants, log: false)

        try do
          id = insert_invitation("referenced@example.test")
          Repo.query!("INSERT INTO app_grants (id, invitation_id) VALUES (?, ?)", ["g1", id])

          error =
            assert_raise ArgumentError, fn ->
              Ecto.Migrator.up(Repo, 31, OpenInTransaction, log: false)
            end

          assert error.message =~ "@disable_ddl_transaction true"
          refute Catalogue.nullable?(Repo, Catalogue.table(Repo, nil, "app_invitations"), :email)

          assert :ok = Ecto.Migrator.up(Repo, 31, OpenOutsideTransaction, log: false)

          assert Catalogue.nullable?(Repo, Catalogue.table(Repo, nil, "app_invitations"), :email)
          assert Repo.query!("SELECT invitation_id FROM app_grants").rows == [[id]]
          assert Repo.query!("PRAGMA foreign_keys").rows == [[1]]

          Repo.query!("DELETE FROM app_grants")
          Repo.query!("DELETE FROM app_invitations")
          assert :ok = Ecto.Migrator.down(Repo, 31, OpenOutsideTransaction, log: false)
        after
          Ecto.Migrator.down(Repo, 30, Grants, log: false)
        end
      end

      test "a SQLite rebuild keeps the application's triggers" do
        Repo.query!("""
        CREATE TRIGGER app_invitations_touch AFTER INSERT ON app_invitations
        BEGIN SELECT 1; END
        """)

        try do
          assert :ok =
                   Ecto.Migrator.up(Repo, 17, Ithibati.AdapterOpenInvitationMigration, log: false)

          assert Repo.query!(
                   "SELECT name FROM sqlite_schema WHERE type = 'trigger' AND tbl_name = 'app_invitations'"
                 ).rows == [["app_invitations_touch"]]
        after
          Repo.query!("DROP TRIGGER IF EXISTS app_invitations_touch")
        end
      end
    end

    defp insert_invitation(email) do
      id = Ecto.UUID.generate()
      dumped = if @sqlite?, do: id, else: Ecto.UUID.dump!(id)

      Repo.query!(
        "INSERT INTO app_invitations (id, email, token_hash, expires_at) VALUES (?, ?, ?, ?)",
        [dumped, email, :crypto.strong_rand_bytes(32), DateTime.utc_now()]
      )

      dumped
    end
  end
end
