defmodule Ithibati.OptedOutUser do
  @moduledoc """
  An account whose application creates the unique index on its identifier itself.

  The same table and identifier as `Ithibati.TestUser`, so a migration driven against either differs
  in exactly one thing: whether this library creates that index or checks for it.
  """
  use Ecto.Schema
  use Ithibati.Schema.User, identifier: :email, unique_index: false

  @primary_key Ithibati.TestKey.primary_key()

  schema "users" do
    ithibati_account()

    timestamps(type: :utc_datetime_usec)
  end
end
