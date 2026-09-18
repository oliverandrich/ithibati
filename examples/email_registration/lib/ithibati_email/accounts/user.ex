defmodule IthibatiEmail.Accounts.User do
  @moduledoc "An account identified by the same email address that received its invitation."
  use Ecto.Schema

  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.User

  use User, identifier: :email, format: Identifier.email_format()

  schema "users" do
    ithibati_account()
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs), do: identifier_changeset(user, attrs)
end
