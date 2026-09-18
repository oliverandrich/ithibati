defmodule IthibatiEmail.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  # Ours, and it runs before Ithibati's: that migration puts the unique index on `token_hash`.
  #
  # The four columns Ithibati reads come from Ithibati, pinned the way its own migration is. What
  # this example would add of its own — a role, a team — goes beside them; there is nothing here
  # because the example is about the flow rather than about what an invitation grants.
  def change do
    create table(:invitations) do
      Ithibati.Migration.invitation_columns(version: 1)

      timestamps(type: :utc_datetime_usec)
    end
  end
end
