defmodule IthibatiOpen.Accounts.User do
  @moduledoc """
  The account table is ours. Ithibati contributes the identifier field, three associations and the
  changeset pieces that validate them — everything else here is this application's.
  """
  use Ecto.Schema

  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.User

  # A username, not an address, and the library's own pattern for one — which is Mastodon's rule
  # for a local account. Your own regex goes here just as well; this is what you get for not having
  # an opinion, and not having one about impersonation is the expensive kind.
  use User, identifier: :username, format: Identifier.username_format()

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
