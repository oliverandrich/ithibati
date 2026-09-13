defmodule IthibatiInvites.Accounts.Invitation do
  @moduledoc """
  The invitations table is ours, the same arrangement as the accounts table.

  Ithibati adds the invitee's identifier, the token digest, an expiry and an acceptance timestamp;
  what an invitation *grants* is this application's to add. There is nothing here beyond the
  minimum, because this example is about the flow rather than about roles.
  """
  use Ecto.Schema

  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.Invitation

  # The same identifier the account schema is keyed by — the configuration refuses the pair when it
  # is not, which is the mistake worth catching at boot rather than at the first invitation.
  use Invitation, identifier: :username, format: Identifier.username_format()

  schema "invitations" do
    ithibati_invitation()

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(invitation, attrs, opts \\ []) do
    invitation_changeset(invitation, attrs, opts)
  end
end
