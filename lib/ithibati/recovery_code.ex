defmodule Ithibati.RecoveryCode do
  @moduledoc """
  One single-use code, stored as a hash, for the day a passkey is gone.

  A spent code is marked rather than deleted: the row is what makes a second use refusable, and how
  many are left is a question the holder gets asked.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Ithibati.Config

  @primary_key {:id, :binary_id, autogenerate: true}

  schema Config.table("recovery_codes") do
    field :code_hash, :binary
    field :used_at, :utc_datetime_usec
    field :user_id, Config.users_key_type()

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(recovery_code, attrs) do
    recovery_code
    |> cast(attrs, [:code_hash, :used_at, :user_id])
    |> validate_required([:code_hash, :user_id])
    |> foreign_key_constraint(:user_id)
  end
end
