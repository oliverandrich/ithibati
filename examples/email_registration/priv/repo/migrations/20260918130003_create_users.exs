defmodule IthibatiEmail.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  # Ours, and it runs first: Ithibati's migration points foreign keys at this table.
  def change do
    create table(:users) do
      add :email, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
