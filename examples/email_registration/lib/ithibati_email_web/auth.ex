defmodule IthibatiEmailWeb.Auth do
  @moduledoc """
  Registration requires an invitation link, including for the first account.

  The invitation approves the email before a challenge is issued. Completion rechecks the link
  and binds it to that approved email, rather than trusting an email posted by the browser.
  Account, invitation acceptance, passkey and recovery codes commit together.
  """
  @behaviour Ithibati.Web.Handler

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_session: 3]

  alias Ecto.Multi
  alias Ithibati.Identity.Grant
  alias Ithibati.Identity.Invitations
  alias Ithibati.Schema
  alias Ithibati.Web.Gate
  alias IthibatiEmail.Accounts.User
  alias IthibatiEmail.Repo

  @impl true
  def registration_subject(_conn, %{"token" => token}) when is_binary(token) do
    case Invitations.fetch(token) do
      nil -> {:error, :invitation_unknown}
      invitation -> {:ok, invitation.email}
    end
  end

  def registration_subject(_conn, _params), do: {:error, :invitation_required}

  @impl true
  def register(conn, key_attrs, email, params) do
    params["token"]
    |> Invitations.fetch()
    |> acceptance(email, key_attrs)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account, recovery_codes: codes}} ->
        {:ok,
         conn
         |> Gate.log_in(account)
         |> put_session(:recovery_codes, codes)
         |> json(%{redirect: "/recovery-codes"})}

      {:error, :account, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, account_error(changeset)}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp acceptance(%{email: email} = invitation, email, key_attrs) do
    Multi.new()
    |> Multi.insert(:account, User.changeset(%User{}, %{email: email}))
    |> Invitations.accept(invitation)
    |> Grant.with_key_and_codes(key_attrs)
  end

  defp acceptance(_invitation, _email, _key_attrs),
    do: Multi.error(Multi.new(), :invitation, :invitation_unknown)

  defp account_error(changeset) do
    if Schema.User.identifier_taken?(changeset), do: :email_taken, else: :invalid_email
  end

  @impl true
  def authenticate(conn, account),
    do: {:ok, conn |> Gate.log_in(account) |> json(%{redirect: "/"})}

  @impl true
  def recovered(conn, account, nil), do: authenticate(conn, account)

  def recovered(conn, account, fresh) do
    {:ok,
     conn
     |> Gate.log_in(account)
     |> put_session(:recovery_codes, fresh)
     |> json(%{redirect: "/recovery-codes"})}
  end
end
