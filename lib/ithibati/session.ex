defmodule Ithibati.Session do
  @moduledoc """
  Stores a session token's SHA-256 digest, account reference and creation time.

  `Ithibati.Identity.Sessions` issues and validates tokens. Deleting the row revokes the token
  for subsequent requests and LiveView mounts. Disconnecting already-open sockets is handled
  separately by `Ithibati.Web.Gate`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Ithibati.Config

  @primary_key {:id, :binary_id, autogenerate: true}

  schema Config.table("sessions") do
    field :token_hash, :binary
    field :user_id, Config.users_key_type()

    # No `updated_at`: a session token is never changed, and its age is its expiry.
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:token_hash, :user_id])
    |> validate_required([:token_hash, :user_id])
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id)
  end
end
