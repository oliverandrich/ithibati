defmodule Ithibati.UserToken do
  @moduledoc """
  One revocable credential. The cookie or the bearer header carries only the token; the row is what
  makes it revocable, and `context` is what makes one kind of token unusable as another.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Ithibati.Config

  @primary_key {:id, :binary_id, autogenerate: true}

  schema Config.table("tokens") do
    field :token, :binary
    field :context, :string
    field :user_id, Config.users_key_type()

    # No `updated_at`: a token is never changed, and its age is its expiry.
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(user_token, attrs) do
    user_token
    |> cast(attrs, [:token, :context, :user_id])
    |> validate_required([:token, :context, :user_id])
    |> unique_constraint(:token)
    |> foreign_key_constraint(:user_id)
  end
end
