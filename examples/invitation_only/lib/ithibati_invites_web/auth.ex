defmodule IthibatiInvitesWeb.Auth do
  @moduledoc """
  The three decisions Ithibati does not make, made here — and this instance makes them narrowly.

  Nobody registers without an invitation, except the first person, who has nobody to invite them.
  Both answers live in `registration_subject/2`, which is asked *before* a challenge is minted: a
  refusal there means no ceremony starts at all, and a token that opens nothing is answered the
  same way as no token.
  """
  @behaviour Ithibati.Web.Handler

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [get_session: 2, put_session: 3]

  alias Ecto.Multi
  alias Ithibati.Identity.Grant
  alias Ithibati.Identity.Instance
  alias Ithibati.Identity.Invitations
  alias Ithibati.Schema
  alias Ithibati.Web.Gate
  alias IthibatiInvites.Accounts.User
  alias IthibatiInvites.Repo

  @impl true
  def registration_subject(conn, params) do
    if Instance.needs_setup?() do
      if Instance.authorized?(get_session(conn, :initial_claim_authorization)),
        do: first_account(params),
        else: {:error, :setup_authorization_required}
    else
      invited(params["token"])
    end
  end

  # The invitation says who this will be, so the browser is not asked. A form that let somebody
  # type their own name here would be a form that lets them accept an invitation addressed to
  # someone else — and `Invitations.accept/2` refuses that anyway, which is where the guarantee is.
  defp invited(token) when is_binary(token) do
    case Invitations.fetch(token) do
      nil -> {:error, :invitation_unknown}
      invitation -> {:ok, invitation.username}
    end
  end

  defp invited(_missing), do: {:error, :invitation_required}

  # Asked before a challenge is minted, so this is where a name the schema could never store has to
  # be refused: approving it means a passkey dialog, a credential the authenticator then keeps, and
  # a refusal only after all of that. The changeset is the authority on the format, so it answers
  # rather than a second copy of the pattern — and it answers with the *normalised* value, so the
  # name on the dialog is the name that will be stored.
  defp first_account(%{"username" => username}) do
    %User{}
    |> User.changeset(%{"username" => username})
    |> Ecto.Changeset.apply_action(:insert)
    |> case do
      {:ok, account} -> {:ok, account.username}
      {:error, _changeset} -> {:error, :invalid_username}
    end
  end

  defp first_account(_params), do: {:error, :username_required}

  @impl true
  def register(conn, key_attrs, username, params) do
    username
    |> acceptance(conn, params["token"], key_attrs)
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

  # Two shapes of the same transaction, and which one this is comes from the same question
  # `registration_subject/2` asked rather than from the request: the browser sends the whole body
  # again at this step, so anything read from `params` here is the client's word for it.
  defp acceptance(username, conn, token, key_attrs) do
    if Instance.needs_setup?(),
      do: claim_instance(username, key_attrs, get_session(conn, :initial_claim_authorization)),
      else: accept_invitation(Invitations.fetch(token), username, key_attrs)
  end

  # The invitation has to be opened a second time, because only the identifier it named travelled
  # with the challenge — and that identifier is what says whether this is the same invitation. One
  # that opens somebody else's is refused here, and `accept/2` refuses it again inside the
  # transaction, where a race cannot get past it.
  defp accept_invitation(%{username: username} = invitation, username, key_attrs) do
    Multi.new()
    |> Multi.insert(:account, User.changeset(%User{}, Invitations.account_attrs(invitation)))
    |> Invitations.accept(invitation)
    |> Grant.with_key_and_codes(key_attrs)
  end

  # Spent, expired, never real, or addressed to somebody else: one answer for all four, so that
  # nothing here tells a guesser which of their guesses was once a link.
  defp accept_invitation(_other, _username, _key_attrs),
    do: Multi.error(Multi.new(), :invitation, :invitation_unknown)

  # Nobody to invite the first person, so this is the one account that arrives without one — and
  # `claim/2` is what stops it from being the second as well. Before the grant, like `accept/2`
  # above: a transaction that is going to be refused should not mint recovery codes on its way to
  # being rolled back, because they sit in plaintext in the `changes_so_far` the caller is handed.
  defp claim_instance(username, key_attrs, authorization) do
    Multi.new()
    |> Multi.insert(:account, User.changeset(%User{}, %{"username" => username}))
    |> Instance.claim(authorization: authorization)
    |> Grant.with_key_and_codes(key_attrs)
  end

  # "Taken" and "not a name" come from different places — the unique index and the format — and
  # only the index can answer the first, since two people may pick one name in the same second.
  # Asked of the library rather than read off the changeset here: it declared that index and is the
  # only party that knows which of this table's unique columns is the identifier.
  defp account_error(changeset) do
    if Schema.User.identifier_taken?(changeset), do: :username_taken, else: :invalid_username
  end

  @impl true
  def authenticate(conn, account),
    do: {:ok, conn |> Gate.log_in(account) |> json(%{redirect: "/"})}

  # The same three lines as the open example, for the same reason: a batch shown once or never.
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
