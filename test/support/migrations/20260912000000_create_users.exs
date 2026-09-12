defmodule Ithibati.TestRepo.Migrations.CreateUsers do
  use Ecto.Migration

  # Everything a real application keeps on an account — name, avatar, roles — is deliberately
  # absent: this is the smallest thing a foreign key can point at.
  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
  end
end
