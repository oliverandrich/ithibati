defmodule Ithibati.Bootstrap do
  @moduledoc """
  The record that an instance has been set up, and by whom.

  A row here is the claim, and there can be at most one. It is a table of this library's rather than
  a flag on the account for two reasons, and the second is the one that decides it.

  The flag would have to be created by the consuming application, on a table this library does not
  own, together with a partial unique index that is the entire guarantee — and forgetting that index
  fails nothing until two people register at the same moment. Here `Ithibati.Migration.up/1` creates
  it, so it cannot be forgotten.

  And a boolean on an account conflates two different facts: *this instance has been set up* and
  *this account set it up*. Delete that account and both vanish, which makes a second setup possible
  again. `user_id` is nullable and nilified on delete, so the row can say the true thing — set up,
  by nobody who is still here.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Ithibati.Config

  @primary_key {:id, :binary_id, autogenerate: true}

  schema Config.table("bootstrap") do
    # Always true. It exists so a unique index can say *at most one row*, which is not otherwise
    # something a table can state about itself.
    field :claimed, :boolean, default: true
    field :user_id, Config.users_key_type()

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Claims the instance for an account.

  Insert it and read the outcome: the second caller of two gets an error on `:claimed`, which is
  what tells "somebody else was first" apart from "this form is wrong".
  """
  def changeset(bootstrap, attrs) do
    bootstrap
    |> cast(attrs, [:user_id])
    |> unique_constraint(:claimed)
    |> foreign_key_constraint(:user_id)
  end
end
