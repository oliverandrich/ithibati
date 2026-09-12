defmodule Ithibati.TestRepo.Migrations.AddIthibati do
  use Ecto.Migration

  # Shaped exactly like the migration a consuming application writes, so the suite exercises the
  # documented path rather than a copy of it. If this stops being what the README tells people to
  # write, the README is wrong and nothing here will say so — keep them equal.
  def up, do: Ithibati.Migration.up(version: 1)
  def down, do: Ithibati.Migration.down(version: 1)
end
