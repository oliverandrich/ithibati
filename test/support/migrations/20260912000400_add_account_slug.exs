defmodule Ithibati.TestRepo.Migrations.AddAccountSlug do
  use Ecto.Migration

  # A unique column of the *application's* own, which a real accounts table has more often than
  # not — a slug, a handle, an invite code. It exists so that `identifier_taken?/1` can be asked
  # about a collision that is not the identifier's and has a way to be wrong.
  #
  # Its own column rather than reusing `nickname`: that one is a display name, written freely by
  # tests that have no reason to expect it to be unique, and a global index on it would turn the
  # second of them into an unexplained `Ecto.ConstraintError`.
  #
  # Its own migration rather than a line in `create_users.exs`, and that is the rule for the next
  # one too: the suite applies migrations it has not seen, so a column added to a file that has
  # already run reaches nobody's existing test database and fails there for a reason the diff does
  # not show.
  def change do
    alter table(:users) do
      add :slug, :string
    end

    create unique_index(:users, [:slug])
  end
end
