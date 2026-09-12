defmodule Ithibati.TestRepo.Migrations.CreateMembers do
  use Ecto.Migration

  # A second consumer-owned account table, identified by a username. Nothing of this library's points
  # at it: what it exercises is the schema macro's one required choice.
  def change do
    create table(:members, primary_key: false) do
      add :id, Ithibati.TestKey.column_type(), primary_key: true
      add :username, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:members, [:username])
  end
end
