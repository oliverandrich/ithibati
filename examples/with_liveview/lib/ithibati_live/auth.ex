defmodule IthibatiLive.Auth do
  @moduledoc """
  The three decisions Ithibati does not make, made here.

  This instance takes one account — the first — which is what `registration_subject/2` is for: it is
  asked before a challenge is minted, so refusing there means no ceremony starts at all.
  """
  @behaviour Ithibati.Web.Handler

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_session: 3]

  alias Ecto.Multi
  alias Ithibati.Identity.Grant
  alias Ithibati.Identity.Instance
  alias Ithibati.Web.Gate
  alias IthibatiLive.Accounts.User
  alias IthibatiLive.Repo

  @impl true
  def registration_subject(_conn, %{"email" => email}) do
    if Instance.needs_setup?(), do: {:ok, email}, else: {:error, :already_claimed}
  end

  def registration_subject(_conn, _params), do: {:error, :email_required}

  @impl true
  def register(conn, key_attrs, email, _params) do
    Multi.new()
    |> Multi.insert(:account, User.changeset(%User{}, %{"email" => email}))
    |> Grant.with_key_and_codes(key_attrs)
    |> Instance.claim()
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

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @impl true
  def authenticate(conn, account),
    do: {:ok, conn |> Gate.log_in(account) |> json(%{redirect: "/"})}
end
