defmodule Ithibati.TestRepo.Migrations.CreateGuests do
  use Ecto.Migration

  # A third consumer-owned account table, whose unique index carries a name Ecto would not derive —
  # `guests_handle_index` is what `unique_constraint/2` would look for on its own. It exists so the
  # `constraint_name:` option is exercised against a real index rather than only accepted.
  def change do
    create table(:guests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :handle, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:guests, [:handle], name: :guests_handle_uniq)
  end
end
