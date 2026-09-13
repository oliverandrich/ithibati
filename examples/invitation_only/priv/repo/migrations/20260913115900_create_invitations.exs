defmodule IthibatiInvites.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  # Ours, and it runs before Ithibati's: that migration puts the unique index on `token_hash`.
  def change do
    create table(:invitations) do
      add :username, :string, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :accepted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end
  end
end
