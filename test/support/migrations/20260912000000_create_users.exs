defmodule Ithibati.TestRepo.Migrations.CreateUsers do
  use Ecto.Migration

  # The table the *consumer* owns, stood up here the way this library's documentation tells an
  # application to stand up its own. Everything a real application keeps on an account beyond this —
  # roles, avatars, profiles — is deliberately absent.
  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :nickname, :string

      timestamps(type: :utc_datetime_usec)
    end
  end
end
