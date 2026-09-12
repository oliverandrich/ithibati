defmodule Ithibati.TestUser do
  @moduledoc """
  Stands in for the account schema a consuming application owns. It will pick up the library's
  schema macro once there is one; until then it is the smallest thing a foreign key can point at.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "users" do
    field :email, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> unique_constraint(:email)
  end
end
