defmodule IthibatiInvites.Registration do
  @moduledoc """
  Optional public requests for invitations, using the same schema as manual invitations.

  Enable both open registration and invitation mail to expose this flow. The initial instance
  claim remains the separate bootstrap flow. A production application must rate-limit public
  requests before calling this function. The example UI gives the same response for every result;
  callers responsible for operations can inspect the error without logging addresses or links.
  """

  alias Ithibati.Identity.Instance
  alias Ithibati.InvitationMail
  alias Ithibati.Schema.Identifier
  alias IthibatiInvites.Accounts.Invitation
  alias IthibatiInvites.Repo
  alias IthibatiInvitesWeb.Endpoint

  def open? do
    Application.get_env(:ithibati_invites, :open_registration, false) == true and
      InvitationMail.enabled?() and not Instance.needs_setup?()
  end

  def request_invitation(username, email) do
    with :ok <- available(),
         :ok <- valid_email(email),
         {:ok, invitation} <- insert_invitation(username) do
      url = Endpoint.url() <> "/invite/" <> invitation.token
      InvitationMail.deliver(email, url)
    end
  end

  defp available do
    cond do
      not open?() -> {:error, :registration_closed}
      Repo.in_transaction?() -> {:error, :transaction_in_progress}
      true -> :ok
    end
  end

  defp valid_email(email) when is_binary(email) do
    if Regex.match?(Identifier.email_format(), email), do: :ok, else: {:error, :invalid_recipient}
  end

  defp valid_email(_email), do: {:error, :invalid_recipient}

  defp insert_invitation(username) when is_binary(username) do
    %Invitation{}
    |> Invitation.changeset(%{username: username})
    |> Repo.insert()
  end

  defp insert_invitation(_username), do: {:error, :invalid_username}
end
