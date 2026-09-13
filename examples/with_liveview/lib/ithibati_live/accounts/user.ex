defmodule IthibatiLive.Accounts.User do
  @moduledoc """
  The account table is ours. Ithibati contributes the identifier field, three associations and the
  changeset pieces that validate them — everything else here is this application's.
  """
  use Ecto.Schema

  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.User

  use User, identifier: :email, format: Identifier.email_format()

  import Ecto.Changeset

  schema "users" do
    ithibati_account()

    field :name, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> identifier_changeset(attrs)
    |> cast(attrs, [:name])
  end
end
