defmodule Ithibati.GuestUser do
  @moduledoc """
  An account whose application names its own indexes, which is a common house convention. The
  library still creates the index; `constraint_name:` only decides what it is called, and without it
  a duplicate would arrive as an unhandled `Ecto.ConstraintError` rather than a message on a form.
  """
  use Ecto.Schema
  use Ithibati.Schema.User, identifier: :handle, constraint_name: :guests_handle_uniq

  @primary_key Ithibati.TestKey.primary_key()

  schema "guests" do
    ithibati_account()

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(guest, attrs), do: identifier_changeset(guest, attrs)
end
