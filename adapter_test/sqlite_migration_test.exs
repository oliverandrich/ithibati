if Application.get_env(:ithibati, :probe_adapter) == Ecto.Adapters.SQLite3 do
  defmodule Ithibati.SQLiteMigrationTest do
    use ExUnit.Case, async: false
    alias Ithibati.AdapterRepo, as: Repo

    setup do
      for {key, value} <- [
            repo: Repo,
            user_schema: Ithibati.SQLiteUser,
            invitation_schema: Ithibati.SQLiteInvitation
          ] do
        previous = Application.get_env(:ithibati, key)
        Application.put_env(:ithibati, key, value)

        on_exit(fn ->
          if previous,
            do: Application.put_env(:ithibati, key, previous),
            else: Application.delete_env(:ithibati, key)
        end)
      end

      Ecto.Migrator.up(Repo, 10, Ithibati.SQLiteApplicationMigration, log: false)
      :ok
    end

    test "invitations can be indexed after the initial library migration" do
      Ecto.Migrator.down(Repo, 11, Ithibati.SQLiteLibraryMigration, log: false)
      Application.delete_env(:ithibati, :invitation_schema)
      assert :ok = Ecto.Migrator.up(Repo, 11, Ithibati.SQLiteLibraryMigration, log: false)
      Application.put_env(:ithibati, :invitation_schema, Ithibati.SQLiteInvitation)
      table = Ithibati.Catalogue.table(Repo, nil, "app_invitations")
      assert {"blob", false} = Ithibati.Catalogue.column(Repo, table, :token_hash)

      try do
        assert :ok =
                 Ecto.Migrator.up(Repo, 12, Ithibati.SQLiteLaterInvitationMigration, log: false)

        assert {"blob", true} = Ithibati.Catalogue.column(Repo, table, :token_hash)
      after
        Ecto.Migrator.down(Repo, 12, Ithibati.SQLiteLaterInvitationMigration, log: false)
        Ecto.Migrator.down(Repo, 11, Ithibati.SQLiteLibraryMigration, log: false)
      end
    end

    test "the library migrates real application tables and rolls back its owned tables" do
      assert Repo.all(Ithibati.SQLiteUser) == []
      Ecto.Migrator.down(Repo, 11, Ithibati.SQLiteLibraryMigration, log: false)
      assert :ok = Ecto.Migrator.up(Repo, 11, Ithibati.SQLiteLibraryMigration, log: false)
      assert Repo.all(Ithibati.UserKey) == []
      assert :ok = Ecto.Migrator.down(Repo, 11, Ithibati.SQLiteLibraryMigration, log: false)
      assert {:error, _} = Repo.query("SELECT id FROM ithibati_keys")
    end
  end
end
