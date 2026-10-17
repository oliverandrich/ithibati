defmodule Ithibati.TestRepo.Migrations.OpenInvitations do
  use Ecto.Migration

  # The suite's invitation tables predate schema version 5, as a consuming application's do. The
  # configured one changes through the library's helper. The other is not configured, so it
  # changes by hand, the way an application with a second invitation schema would.
  def up do
    Ithibati.Migration.open_invitations(version: 5)

    alter table(:odd_invitations) do
      add :note, :text
      modify :email, :string, null: true
    end
  end

  def down do
    alter table(:odd_invitations) do
      remove :note
      modify :email, :string, null: false
    end

    Ithibati.Migration.open_invitations(version: 5)
  end
end
