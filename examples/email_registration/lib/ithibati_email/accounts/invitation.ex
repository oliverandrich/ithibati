defmodule IthibatiEmail.Accounts.Invitation do
  @moduledoc "An invitation addressed to the future account's email identifier."
  use Ecto.Schema

  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.Invitation

  use Invitation, identifier: :email, format: Identifier.email_format()

  schema "invitations" do
    ithibati_invitation()
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(invitation, attrs, opts \\ []), do: invitation_changeset(invitation, attrs, opts)
end
