defmodule Ithibati.TestRepo.Migrations.CreateInvitations do
  use Ecto.Migration

  # The table a *consuming application* owns, stood up the way this library's documentation tells an
  # application to stand up its own: the library's columns, and the one that says what the invitation
  # grants. The unique index on the digest is the library's to check or create, so it is deliberately
  # absent here, and this migration runs before the library's, which is the order a consuming
  # application follows too.
  def change do
    create table(:invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :accepted_at, :utc_datetime_usec
      add :role, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # The same table under an application that named its primary key something else, which is a
    # choice this library leaves open and therefore has to keep working.
    create table(:odd_invitations, primary_key: false) do
      add :invitation_id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :accepted_at, :utc_datetime_usec
    end

    # This one the application maintains itself, which is what `unique_index: false` on
    # `Ithibati.OddInvitation` says — the pair has to agree, or the fixture describes an arrangement
    # nobody could have.
    create unique_index(:odd_invitations, [:token_hash])
  end
end
