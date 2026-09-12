defmodule Ithibati.GuestUser do
  @moduledoc """
  An account whose application names its own indexes, which is a common house convention — and
  which without `constraint_name:` ends in an unhandled `Ecto.ConstraintError` on the second
  registration rather than a message on a form.
  """
  use Ecto.Schema
  use Ithibati.Schema.User, identifier: :handle, constraint_name: :guests_handle_uniq

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "guests" do
    ithibati_account()

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(guest, attrs), do: identifier_changeset(guest, attrs)
end
