defmodule IthibatiInvites.Repo.Migrations.AddSetupCodes do
  use Ecto.Migration
  def up, do: Ithibati.Migration.up(from: 2, version: 3)
  def down, do: Ithibati.Migration.down(from: 2, version: 3)
end
