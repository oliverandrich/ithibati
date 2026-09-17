if Application.compile_env!(:ithibati, :probe_adapter) == Ecto.Adapters.SQLite3 do
  defmodule Ithibati.SQLiteUser do
    @moduledoc false
    use Ecto.Schema
    use Ithibati.Schema.User, identifier: :email
    @primary_key {:id, Ithibati.Config.users_key_type(), autogenerate: true}
    schema "app_users" do
      ithibati_account()
      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule Ithibati.SQLiteInvitation do
    @moduledoc false
    use Ecto.Schema
    use Ithibati.Schema.Invitation, identifier: :email
    @primary_key {:id, :binary_id, autogenerate: true}
    schema "app_invitations" do
      ithibati_invitation()
    end
  end

  defmodule Ithibati.SQLiteApplicationMigration do
    @moduledoc false
    use Ecto.Migration

    def change do
      create table(:app_users, primary_key: false) do
        add :id,
            if(Application.get_env(:ithibati, :users_key_type, :binary_id) == :id,
              do: :integer,
              else: :binary_id
            ),
            primary_key: true

        add :email, :string, null: false
        timestamps(type: :utc_datetime_usec)
      end

      create table(:app_invitations, primary_key: false) do
        add :id, :binary_id, primary_key: true
        Ithibati.Migration.invitation_columns(version: 1)
      end
    end
  end

  defmodule Ithibati.SQLiteLibraryMigration do
    @moduledoc false
    use Ecto.Migration
    def up, do: Ithibati.Migration.up(version: 1)
    def down, do: Ithibati.Migration.down(version: 1)
  end

  defmodule Ithibati.SQLiteLaterInvitationMigration do
    @moduledoc false
    use Ecto.Migration
    def up, do: Ithibati.Migration.invitation_index(version: 1)
    def down, do: drop(index(:app_invitations, [:token_hash]))
  end
end
