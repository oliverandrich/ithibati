defmodule Ithibati.RecoveryCode do
  @moduledoc """
  Stores a recovery code's digest, account reference and usage timestamp.

  `used_at` is `nil` until redemption. `Ithibati.Identity.RecoveryCodes` checks and marks the code
  in the same write so concurrent callers cannot both redeem it. Plaintext codes are not stored.
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
