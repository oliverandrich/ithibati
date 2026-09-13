defmodule Ithibati.TestUser do
  @moduledoc """
  Stands in for the account schema a consuming application owns: it uses the library's macro and
  adds one field of its own, which is the shape the macro's documentation describes.
  """
  use Ecto.Schema

  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.User

  use User, identifier: :email, format: Identifier.email_format()

  import Ecto.Changeset

  @primary_key Ithibati.TestKey.primary_key()

  schema "users" do
    ithibati_account()

    field :nickname, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> identifier_changeset(attrs)
    |> cast(attrs, [:nickname])
  end
end

defmodule Ithibati.NamedUser do
  @moduledoc """
  The same account, with a better name for a person than its identifier. Identical to
  `Ithibati.TestUser` on purpose: what it isolates is the override.
  """
  use Ecto.Schema

  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.User

  use User, identifier: :email, format: Identifier.email_format()

  @primary_key Ithibati.TestKey.primary_key()

  schema "users" do
    ithibati_account()

    field :nickname, :string

    timestamps(type: :utc_datetime_usec)
  end

  # Written as the documentation shows it: no fallback, because `nil` is a correct answer and the
  # library owns what happens next.
  def passkey_display_name(account), do: account.nickname
end
