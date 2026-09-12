defmodule Ithibati.NamedUser do
  @moduledoc """
  An account schema that has a better name for a person than its identifier, and says so. The same
  table as `Ithibati.TestUser`; what it exists to show is the override.
  """
  use Ecto.Schema
  use Ithibati.Schema.User

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "users" do
    ithibati_account()

    field :nickname, :string

    timestamps(type: :utc_datetime_usec)
  end

  # Written exactly as the documentation shows it: no fallback, because `nil` is a correct answer
  # and the library owns what happens next.
  def passkey_display_name(account), do: account.nickname
end
