defmodule Ithibati.TestUser do
  @moduledoc """
  Stands in for the account schema a consuming application owns: it uses the library's macro and
  adds one field of its own, which is exactly the shape the macro's documentation describes.
  """
  use Ecto.Schema
  use Ithibati.Schema.User

  import Ecto.Changeset

  alias Ithibati.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "users" do
    ithibati_account()

    field :nickname, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> Schema.User.email_changeset(attrs)
    |> cast(attrs, [:nickname])
  end
end
