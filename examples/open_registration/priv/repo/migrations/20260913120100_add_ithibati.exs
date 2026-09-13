defmodule IthibatiOpen.Repo.Migrations.AddIthibati do
  use Ecto.Migration

  # Pinned, as the README says: an unpinned call would mean a different set of tables depending on
  # when it ran, and a rollback that undoes neither.
  def up, do: Ithibati.Migration.up(version: 1)
  def down, do: Ithibati.Migration.down(version: 1)
end
