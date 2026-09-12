defmodule Ithibati.OptedOutUser do
  @moduledoc """
  An account whose application maintains the unique index on its identifier itself.

  The same table and identifier as `Ithibati.TestUser`, so a migration driven against either differs
  in exactly one thing: whether this library creates that index.
  """
  use Ecto.Schema
  use Ithibati.Schema.User, identifier: :email, constraint_name: :users_email_uniq

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "users" do
    ithibati_account()

    field :nickname, :string

    timestamps(type: :utc_datetime_usec)
  end
end
