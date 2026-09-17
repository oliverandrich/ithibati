if Application.get_env(:ithibati, :probe_adapter) in [Ecto.Adapters.SQLite3, Ecto.Adapters.MyXQL] do
  defmodule Ithibati.AdapterMigrationTest do
    use ExUnit.Case, async: false
    alias Ithibati.AdapterIdentityRepo, as: Repo

    setup do
      for {key, value} <- [
            repo: Repo,
            user_schema: Ithibati.AdapterUser,
            invitation_schema: Ithibati.AdapterInvitation
          ] do
        previous = Application.get_env(:ithibati, key)
        Application.put_env(:ithibati, key, value)

        on_exit(fn ->
          if previous,
            do: Application.put_env(:ithibati, key, previous),
            else: Application.delete_env(:ithibati, key)
        end)
      end

      Ecto.Migrator.up(Repo, 10, Ithibati.AdapterApplicationMigration, log: false)
      :ok
    end

    test "invitations can be indexed after the initial library migration" do
      Ecto.Migrator.down(Repo, 11, Ithibati.AdapterLibraryMigration, log: false)
      Application.delete_env(:ithibati, :invitation_schema)
      assert :ok = Ecto.Migrator.up(Repo, 11, Ithibati.AdapterLibraryMigration, log: false)
      Application.put_env(:ithibati, :invitation_schema, Ithibati.AdapterInvitation)
      table = Ithibati.Catalogue.table(Repo, nil, "app_invitations")
      type = if Repo.__adapter__() == Ecto.Adapters.MyXQL, do: "varbinary(32)", else: "blob"
      assert {^type, false} = Ithibati.Catalogue.column(Repo, table, :token_hash)

      try do
        assert :ok =
                 Ecto.Migrator.up(Repo, 12, Ithibati.AdapterLaterInvitationMigration, log: false)

        assert {^type, true} = Ithibati.Catalogue.column(Repo, table, :token_hash)
      after
        Ecto.Migrator.down(Repo, 12, Ithibati.AdapterLaterInvitationMigration, log: false)
        Ecto.Migrator.down(Repo, 11, Ithibati.AdapterLibraryMigration, log: false)
      end
    end

    test "the library migrates real application tables and rolls back its owned tables" do
      assert Repo.all(Ithibati.AdapterUser) == []
      Ecto.Migrator.down(Repo, 11, Ithibati.AdapterLibraryMigration, log: false)
      assert :ok = Ecto.Migrator.up(Repo, 11, Ithibati.AdapterLibraryMigration, log: false)
      assert Repo.all(Ithibati.UserKey) == []
      assert :ok = Ecto.Migrator.down(Repo, 11, Ithibati.AdapterLibraryMigration, log: false)
      assert {:error, _} = Repo.query("SELECT id FROM ithibati_keys")
    end
  end
end
