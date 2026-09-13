defmodule IthibatiInvites.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  # Ours, and it runs first: Ithibati's migration points foreign keys at this table.
  def change do
    create table(:users) do
      add :username, :string, null: false
      add :name, :string

      timestamps(type: :utc_datetime_usec)
    end
  end
end
