defmodule IthibatiEmailWeb.CeremonyMessages do
  @moduledoc """
  One sentence per reason a ceremony can fail, in one place.

  The reasons arrive as the codes `IthibatiEmailWeb.Auth` returned, plus the ones the library
  produces. Turning them into sentences is the application's job — a library that shipped the
  wording would be deciding the tone of somebody else's product — and both pages that can start a
  ceremony ask here, because the same code answered two ways is how a vocabulary drifts.
  """

  @doc """
  A sentence for the `ithibati:failed` code, or an honest fallback for one nobody listed.

  Both pages call this one, with the code and the `exception` the payload carried. That second
  value is the `DOMException` name when a browser refused, and `nil` otherwise.
  """
  def message("ceremony_failed", name) when is_binary(name), do: "Your browser refused: #{name}."
  def message(code, _name), do: sentence(code)

  defp sentence("invitation_required"), do: "Open the registration link from your email first."
  defp sentence("invitation_unknown"), do: "That invitation has been used, or has expired."
  defp sentence("email_taken"), do: "That email address already has an account."

  defp sentence("invalid_email"),
    do: "Enter a valid email address."

  defp sentence("no_credentials"), do: "No passkey is registered here yet."
  defp sentence("ceremony_cancelled"), do: "The passkey prompt was dismissed."

  defp sentence("already_enrolled"), do: "That device already holds a passkey for this site."

  defp sentence("identifier_mismatch"),
    do: "That invitation was not addressed to that email address."

  defp sentence("invalid_code"), do: "That recovery code is not one we can use."
  defp sentence("no_challenge"), do: "That took too long. Start again."
  defp sentence("malformed_credential"), do: "Your browser sent something this site cannot read."

  defp sentence("not_discoverable"),
    do: "That device will not store a passkey this site can find."

  defp sentence("unknown_credential"), do: "That passkey is not one this site knows."
  defp sentence("no_attested_credential"), do: "Your browser sent no passkey to store."
  defp sentence("credential_id_too_long"), do: "That passkey is bigger than this site can store."
  defp sentence("verification_failed"), do: "That did not check out. Start again."
  defp sentence("ceremony_failed"), do: "Your browser stopped partway through."
  defp sentence("recovery_failed"), do: "That code never reached us. Try again."
  defp sentence("unknown"), do: "That request failed without saying why."

  # Your own codes land here, and so do the two families that carry a suffix.
  defp sentence(other), do: "Something went wrong: #{other}"
end
