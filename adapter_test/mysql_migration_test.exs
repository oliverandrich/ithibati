if Application.get_env(:ithibati, :probe_adapter) == Ecto.Adapters.MyXQL do
  defmodule Ithibati.MySQLMigrationRecovery do
    use Ecto.Migration
    def up, do: Ithibati.Migration.down(version: 1)
    def down, do: :ok
  end

  defmodule Ithibati.MySQLMigrationTest do
    use Ithibati.AdapterIdentityCase
    alias Ithibati.AdapterLibraryMigration
    alias Ithibati.Catalogue

    test "a conflicting application index is refused before creating library tables" do
      Ecto.Migrator.down(Repo, 11, AdapterLibraryMigration, log: false)
      Repo.query!("CREATE INDEX app_users_email_index ON app_users(email)")

      try do
        assert_raise ArgumentError, ~r/unique index/, fn ->
          Ecto.Migrator.up(Repo, 11, AdapterLibraryMigration, log: false)
        end

        assert Catalogue.table(Repo, nil, "ithibati_keys") == nil
      after
        Repo.query!("DROP INDEX app_users_email_index ON app_users")
        recover()
      end
    end

    test "incompatible key widths and signedness fail before library DDL" do
      Ecto.Migrator.down(Repo, 11, AdapterLibraryMigration, log: false)

      {bad, good} =
        if Ithibati.Config.users_key_type() == :id,
          do: {"INT UNSIGNED", "BIGINT UNSIGNED"},
          else: {"BINARY(15)", "BINARY(16)"}

      Repo.query!("ALTER TABLE app_users MODIFY id #{bad} NOT NULL")

      try do
        assert_raise ArgumentError, ~r/foreign key cannot bridge/, fn ->
          Ecto.Migrator.up(Repo, 11, AdapterLibraryMigration, log: false)
        end

        assert Catalogue.table(Repo, nil, "ithibati_keys") == nil
      after
        auto = if Ithibati.Config.users_key_type() == :id, do: " AUTO_INCREMENT", else: ""
        Repo.query!("ALTER TABLE app_users MODIFY id #{good} NOT NULL#{auto}")
        Ecto.Migrator.up(Repo, 11, AdapterLibraryMigration, log: false)
      end
    end

    test "explicit rollback cleans a partial MySQL migration before retrying" do
      Ecto.Migrator.down(Repo, 11, AdapterLibraryMigration, log: false)
      Repo.query!("CREATE TABLE ithibati_keys (id BINARY(16) PRIMARY KEY) ENGINE=InnoDB")
      recover()

      assert {"varbinary(1023)", true} =
               Catalogue.column(Repo, Catalogue.table(Repo, nil, "ithibati_keys"), :key_id)
    end

    if Application.compile_env!(:ithibati, :users_key_type) == :id do
      test "signed BIGINT accounts and keys above 32 bits retain compatible references" do
        Ecto.Migrator.down(Repo, 11, AdapterLibraryMigration, log: false)
        Repo.query!("ALTER TABLE app_users MODIFY id BIGINT NOT NULL AUTO_INCREMENT")

        try do
          Ecto.Migrator.up(Repo, 11, AdapterLibraryMigration, log: false)
          assert {"bigint", _} = Catalogue.column(Repo, {:mysql, "ithibati_keys"}, :user_id)
          user = Repo.insert!(%User{id: 4_294_967_296, email: "large@example.test"})
          key = key(user)
          assert Repo.get!(Ithibati.UserKey, key.id).user_id == 4_294_967_296
          Repo.delete!(user)
        after
          Repo.delete_all(User)
          Ecto.Migrator.down(Repo, 11, AdapterLibraryMigration, log: false)
          Repo.query!("ALTER TABLE app_users MODIFY id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT")
          Ecto.Migrator.up(Repo, 11, AdapterLibraryMigration, log: false)
        end
      end
    end

    defp recover do
      Ecto.Migrator.up(Repo, 13, Ithibati.MySQLMigrationRecovery, log: false)
      Ecto.Migrator.down(Repo, 13, Ithibati.MySQLMigrationRecovery, log: false)
      Ecto.Migrator.up(Repo, 11, AdapterLibraryMigration, log: false)
    end
  end
end
