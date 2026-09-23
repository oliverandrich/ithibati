defmodule Ithibati.TestRepo.Migrations.AddInvitedBy do
  use Ecto.Migration

  # The suite's invitation tables predate schema version 4, exactly as a consuming application's
  # do, so the column arrives the way the guide tells them to add it: a migration of its own
  # rather than an edit to one already applied, and the library's helper rather than a hand-typed
  # column, because the type follows the account key this run was compiled for.
  def change do
    alter table(:invitations) do
      Ithibati.Migration.invitation_inviter_column(version: 4)
    end

    alter table(:odd_invitations) do
      Ithibati.Migration.invitation_inviter_column(version: 4)
    end
  end
end
