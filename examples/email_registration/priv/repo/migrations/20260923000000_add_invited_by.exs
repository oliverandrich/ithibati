defmodule IthibatiEmail.Repo.Migrations.AddInvitedBy do
  use Ecto.Migration

  # This application turned invitations on before schema version 4, so the column arrives in a
  # migration of its own. A table created with `invitation_columns(version: 4)` already has it.
  def change do
    alter table(:invitations) do
      Ithibati.Migration.invitation_inviter_column(version: 4)
    end
  end
end
