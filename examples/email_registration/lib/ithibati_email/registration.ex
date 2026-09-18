defmodule IthibatiEmail.Registration do
  @moduledoc """
  Open registration through email, using the existing invitation schema and delivery API.

  A request creates only an invitation. Following its link creates the account with a passkey.
  The normalized invitation email is also the mail recipient; there is no separate address.
  Production applications must rate-limit public requests per source and recipient before calling
  this function. The UI gives every request a neutral response; this function returns errors to
  application callers without logging addresses or links.
  """

  alias Ithibati.InvitationMail
  alias IthibatiEmail.Accounts.Invitation
  alias IthibatiEmail.Repo
  alias IthibatiEmailWeb.Endpoint

  def open?, do: InvitationMail.enabled?()

  def request_invitation(email) do
    with :ok <- available(),
         {:ok, invitation} <- insert_invitation(email) do
      url = Endpoint.url() <> "/invite/" <> invitation.token
      InvitationMail.deliver(invitation.email, url)
    end
  end

  defp available do
    cond do
      not open?() -> {:error, :registration_closed}
      Repo.in_transaction?() -> {:error, :transaction_in_progress}
      true -> :ok
    end
  end

  defp insert_invitation(email) when is_binary(email) do
    %Invitation{}
    |> Invitation.changeset(%{email: email})
    |> Repo.insert()
  end

  defp insert_invitation(_email), do: {:error, :invalid_email}
end
