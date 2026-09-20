if Application.compile_env!(:ithibati, :probe_adapter) in [
     Ecto.Adapters.SQLite3,
     Ecto.Adapters.MyXQL
   ] do
  defmodule Ithibati.AdapterUser do
    @moduledoc false
    use Ecto.Schema
    use Ithibati.Schema.User, identifier: :email
    @primary_key {:id, Ithibati.Config.users_key_type(), autogenerate: true}
    schema "app_users" do
      ithibati_account()
      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule Ithibati.AdapterInvitation do
    @moduledoc false
    use Ecto.Schema
    use Ithibati.Schema.Invitation, identifier: :email
    @primary_key {:id, :binary_id, autogenerate: true}
    schema "app_invitations" do
      ithibati_invitation()
    end
  end

  defmodule Ithibati.AdapterApplicationMigration do
    @moduledoc false
    use Ecto.Migration

    def change do
      create table(:app_users, primary_key: false) do
        add :id,
            if(Application.get_env(:ithibati, :users_key_type, :binary_id) == :id,
              do: :bigserial,
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

  defmodule Ithibati.AdapterLibraryMigration do
    @moduledoc false
    use Ecto.Migration
    def up, do: Ithibati.Migration.up(version: 1)
    def down, do: Ithibati.Migration.down(version: 1)
  end

  defmodule Ithibati.AdapterChallengeMigration do
    @moduledoc false
    use Ecto.Migration
    def up, do: Ithibati.Migration.up(from: 1, version: 2)
    def down, do: Ithibati.Migration.down(from: 1, version: 2)
  end

  defmodule Ithibati.AdapterSetupCodeMigration do
    @moduledoc false
    use Ecto.Migration
    def up, do: Ithibati.Migration.up(from: 2, version: 3)
    def down, do: Ithibati.Migration.down(from: 2, version: 3)
  end

  defmodule Ithibati.AdapterLaterInvitationMigration do
    @moduledoc false
    use Ecto.Migration
    def up, do: Ithibati.Migration.invitation_index(version: 1)
    def down, do: drop(index(:app_invitations, [:token_hash]))
  end
end

if Application.compile_env!(:ithibati, :probe_adapter) in [
     Ecto.Adapters.SQLite3,
     Ecto.Adapters.MyXQL
   ] do
  defmodule Ithibati.AdapterIdentityRepo do
    @moduledoc false
    use Ecto.Repo,
      otp_app: :ithibati,
      adapter: Application.compile_env!(:ithibati, :probe_adapter)
  end
end
