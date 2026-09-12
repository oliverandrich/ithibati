defmodule Ithibati.NamedIndexUser do
  @moduledoc """
  An account whose application names its own indexes but lets the library create them.

  The same table and identifier as `Ithibati.TestUser`; the one variable is `constraint_name:`.
  """
  use Ecto.Schema
  use Ithibati.Schema.User, identifier: :email, constraint_name: :users_email_house

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "users" do
    ithibati_account()

    timestamps(type: :utc_datetime_usec)
  end
end
