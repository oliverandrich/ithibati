defmodule IthibatiOpen.Auth do
  @moduledoc """
  The three decisions Ithibati does not make, made here.

  Registration is open: anyone who picks a free username gets an account. That makes
  `registration_subject/2` the shortest it can be — and it is still the right place for the answer,
  because it is asked *before* a challenge is minted, so an instance that refuses somebody says so
  there and no ceremony starts at all. The invitation example is the other end of the same hinge.
  """
  @behaviour Ithibati.Web.Handler

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_session: 3]

  alias Ecto.Multi
  alias Ithibati.Identity.Grant
  alias Ithibati.Web.Gate
  alias IthibatiOpen.Accounts.User
  alias IthibatiOpen.Repo

  @impl true
  # Asked before a challenge is minted, so this is where a name the schema could never store has to
  # be refused: approving it means a passkey dialog, a credential the authenticator then keeps, and
  # a refusal only after all of that. The changeset is the authority on the format, so it answers
  # rather than a second copy of the pattern — and it answers with the *normalised* value, so the
  # name on the dialog is the name that will be stored.
  def registration_subject(_conn, %{"username" => username}) do
    %User{}
    |> User.changeset(%{"username" => username})
    |> Ecto.Changeset.apply_action(:insert)
    |> case do
      {:ok, account} -> {:ok, account.username}
      {:error, _changeset} -> {:error, :invalid_username}
    end
  end

  def registration_subject(_conn, _params), do: {:error, :username_required}

  @impl true
  def register(conn, key_attrs, username, _params) do
    Multi.new()
    |> Multi.insert(:account, User.changeset(%User{}, %{"username" => username}))
    |> Grant.with_key_and_codes(key_attrs)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account, recovery_codes: codes}} ->
        # The codes are the only copy — the rows hold digests — so they go somewhere the person
        # will see them, once. Into the session here and onto their own page after the redirect,
        # because a LiveView cannot clear a session key and these must not survive being read.
        #
        # Answering with a redirect rather than a body: signing in renews the session, the CSRF
        # token with it, so the page has to be loaded afresh. The hook follows this.
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

  # "Taken" and "not a name" come from different places — the unique index and the format — and only
  # the index can answer the first, since two people may pick one name in the same second. Reading
  # the constraint off the error is what keeps a malformed name from being reported as somebody
  # else's.
  defp account_error(changeset) do
    taken? =
      Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
        opts[:constraint] == :unique
      end)

    if taken?, do: :username_taken, else: :invalid_username
  end

  @impl true
  def authenticate(conn, account),
    do: {:ok, conn |> Gate.log_in(account) |> json(%{redirect: "/"})}
end
