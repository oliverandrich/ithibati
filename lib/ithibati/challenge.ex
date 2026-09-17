defmodule Ithibati.Challenge do
  @moduledoc "Stores the digest and expiry of an outstanding WebAuthn challenge."
  use Ecto.Schema

  @primary_key {:token_hash, :binary, autogenerate: false}
  schema Ithibati.Config.table("challenges") do
    field :expires_at, :utc_datetime_usec
  end
end
