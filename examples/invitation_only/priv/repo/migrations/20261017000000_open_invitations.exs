defmodule IthibatiInvites.Repo.Migrations.OpenInvitations do
  use Ecto.Migration

  # This application created its invitation table before schema version 5, so the table opens in
  # a migration of its own. `up/1` then checks it at version 5.
  def up do
    Ithibati.Migration.open_invitations(version: 5)
    Ithibati.Migration.up(from: 3, version: 5)
  end

  def down do
    Ithibati.Migration.down(from: 3, version: 5)
    Ithibati.Migration.open_invitations(version: 5)
  end
end
