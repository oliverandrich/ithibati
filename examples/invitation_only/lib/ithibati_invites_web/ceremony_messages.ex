defmodule IthibatiInvitesWeb.CeremonyMessages do
  @moduledoc """
  One sentence per reason a ceremony can fail, in one place.

  The reasons arrive as the codes `IthibatiInvitesWeb.Auth` returned, plus the ones the library
  produces. Turning them into sentences is the application's job — a library that shipped the
  wording would be deciding the tone of somebody else's product — and both pages that can start a
  ceremony ask here, because the same code answered two ways is how a vocabulary drifts.
  """

  @doc "A sentence for the `ithibati:failed` code, or an honest fallback for one nobody listed."
  def message("invitation_required"), do: "This instance is invitation-only."
  def message("invitation_unknown"), do: "That invitation has been used, or has expired."
  def message("username_taken"), do: "That username is taken."

  def message("invalid_username"),
    do: "A username is letters, digits and underscores, up to thirty characters."

  def message("username_required"), do: "Pick a username to claim this instance."
  def message("no_credentials"), do: "No passkey is registered here yet."
  def message("ceremony_cancelled"), do: "The passkey prompt was dismissed."

  def message("already_enrolled"), do: "That device already holds a passkey for this site."
  def message(other), do: "Something went wrong: #{other}"
end
