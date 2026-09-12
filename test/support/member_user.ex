defmodule Ithibati.MemberUser do
  @moduledoc """
  An account identified by a username rather than an address, on a table of its own.

  It exists so the suite exercises the choice rather than only the option: an application that never
  wants to know an address should be able to say so, and nothing here should have to be an email.
  """
  use Ecto.Schema
  use Ithibati.Schema.User, identifier: :username, format: ~r/^[a-z0-9][a-z0-9_-]{2,31}$/

  @primary_key Ithibati.TestKey.primary_key()

  schema "members" do
    ithibati_account()

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(member, attrs), do: identifier_changeset(member, attrs)
end
