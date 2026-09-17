# Invitations and the first account

Adapt the application from [Getting started](getting_started.md) so the first account claims
the instance and subsequent accounts need an invitation. Your application owns the invitation
table and decides who may issue links and what accepting one grants.

This guide uses username identifiers, matching the walkthrough. For finished code, see the
[invitation-only example](https://github.com/oliverandrich/ithibati/tree/main/examples/invitation_only).

## 1. The invitation schema

Create `lib/my_app/accounts/invitation.ex`:

```elixir
defmodule MyApp.Accounts.Invitation do
  use Ecto.Schema

  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.Invitation

  use Invitation, identifier: :username, format: Identifier.username_format()

  schema "invitations" do
    ithibati_invitation()
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(invitation, attrs, opts \\ []) do
    invitation_changeset(invitation, attrs, opts)
  end
end
```

The macro adds the identifier, `token_hash`, `expires_at`, `accepted_at` and a virtual `token`.
The identifier field must match the account schema's identifier. Add your own fields for a
role, team or other grant, together with their changeset handling and migration columns.

A new invitation lasts seven days by default. `invitation_changeset/3` accepts `days:`; using
it on an existing invitation can extend the expiry while preserving its token.

The changeset checks whether an account already has the identifier. The account table's unique
index remains the final guarantee when registrations happen concurrently.

## 2. Configure and migrate

Add this to `config/config.exs`:

```elixir
config :ithibati, invitation_schema: MyApp.Accounts.Invitation
```

Generate a migration:

```console
$ mix ecto.gen.migration create_invitations
```

Use the following body in the generated file:

```elixir
defmodule MyApp.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  def change do
    create table(:invitations) do
      Ithibati.Migration.invitation_columns(version: 1)
      timestamps(type: :utc_datetime_usec)
    end

    Ithibati.Migration.invitation_index(version: 1)
  end
end
```

The explicit index call matters when Ithibati's initial migration has already run, as it has
in the walkthrough. It creates the token's unique index if absent and can coexist with an
initial migration that also creates it.

```console
$ mix ecto.migrate
```

`invitation_columns/1` adds these columns:

| Column | Type | Nullable |
| --- | --- | --- |
| Your configured identifier | `:string` | No |
| `token_hash` | `:binary` | No |
| `expires_at` | `:utc_datetime_usec` | No |
| `accepted_at` | `:utc_datetime_usec` | Yes |

The plaintext token is virtual and is not stored. For an existing table, supply the same
columns and required index. If your account identifier uses `citext`, write the column
definitions explicitly with the corresponding identifier type; the helper emits `:string`.

## 3. Replace the registration handler

Replace `lib/my_app_web/auth.ex` with this handler. It retains authentication and recovery from
the walkthrough and adds the two registration paths:

```elixir
defmodule MyAppWeb.Auth do
  @behaviour Ithibati.Web.Handler

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_session: 3]

  alias Ecto.Multi
  alias Ithibati.Identity.Grant
  alias Ithibati.Identity.Instance
  alias Ithibati.Identity.Invitations
  alias Ithibati.Web.Gate
  alias MyApp.Accounts.User
  alias MyApp.Repo

  @impl true
  def registration_subject(_conn, params) do
    if Instance.needs_setup?(),
      do: first_account(params),
      else: invited(params["token"])
  end

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

  defp invited(token) do
    case Invitations.fetch(token) do
      nil -> {:error, :invitation_unknown}
      invitation -> {:ok, invitation.username}
    end
  end

  @impl true
  def register(conn, key_attrs, username, params) do
    registration_multi(username, params["token"], key_attrs)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account, recovery_codes: codes}} ->
        {:ok,
         conn
         |> Gate.log_in(account)
         |> put_session(:recovery_codes, codes)
         |> json(%{redirect: "/recovery-codes"})}

      {:error, :account, %Ecto.Changeset{} = changeset, _changes} ->
        if Ithibati.Schema.User.identifier_taken?(changeset),
          do: {:error, :username_taken},
          else: {:error, :invalid_username}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @impl true
  def authenticate(conn, account),
    do: {:ok, conn |> Gate.log_in(account) |> json(%{redirect: "/inside"})}

  @impl true
  def recovered(conn, account, nil), do: authenticate(conn, account)

  def recovered(conn, account, fresh) do
    {:ok,
     conn
     |> Gate.log_in(account)
     |> put_session(:recovery_codes, fresh)
     |> json(%{redirect: "/recovery-codes"})}
  end

  defp registration_multi(username, token, key_attrs) do
    account = User.changeset(%User{}, %{"username" => username})

    if Instance.needs_setup?() do
      Multi.new()
      |> Multi.insert(:account, account)
      |> Instance.claim()
      |> Grant.with_key_and_codes(key_attrs)
    else
      case Invitations.fetch(token) do
        nil ->
          Multi.new() |> Multi.error(:invitation, :invalid_invitation)

        invitation ->
          Multi.new()
          |> Multi.insert(:account, account)
          |> Invitations.accept(invitation)
          |> Grant.with_key_and_codes(key_attrs)
      end
    end
  end

end
```

`Instance.needs_setup?/0` selects the path for the request. `Instance.claim/2` enforces the
one-time claim inside the transaction, including when two people try concurrently. A losing
claim returns `{:error, :bootstrap, :already_claimed, changes}` and rolls back the account.

`Invitations.fetch/1` returns a pending, unexpired invitation or `nil`. The handler checks again
at completion and handles `nil` before calling `accept/3`. An invitation can expire or be spent
between the challenge and the response.

`Invitations.accept/3` checks the invitation's state again when it writes. It also compares its
identifier with the account inserted by the `:account` step. A mismatch returns
`:identifier_mismatch`; an invitation that can no longer be accepted returns `:invalid_invitation`.

**Build the account from the approved `username` argument.** The final request's token may
differ from the one used to obtain the challenge. Rebuilding the account from that token's
invitation would bypass the binding to the identifier originally approved.

Missing, unknown, expired and spent tokens all receive `:invitation_unknown` at the challenge
step in this example. Your page can show one message for them.

## 4. Add the invitation page

Add `live "/invite/:token", InviteLive` inside the public `live_session` in your router.
Create `lib/my_app_web/live/invite_live.ex`:

```elixir
defmodule MyAppWeb.InviteLive do
  use MyAppWeb, :live_view

  alias Ithibati.Identity.Invitations

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok, assign(socket, token: token, invitation: Invitations.fetch(token), error: nil)}
  end

  @impl true
  def handle_event("accept", _params, socket),
    do: {:noreply, push_event(socket, "ithibati:register", %{token: socket.assigns.token})}

  def handle_event("ithibati:failed", %{"error" => error} = payload, socket),
    do: {:noreply, assign(socket, error: message(error, payload["exception"]))}

  def handle_event("ithibati:done", _payload, socket), do: {:noreply, socket}

  defp message("ceremony_failed", name) when is_binary(name),
    do: "Your browser refused: #{name}."

  defp message(error, _name), do: message(error)

  defp message("invitation_unknown"), do: "This invitation is unavailable or has expired."
  defp message("invalid_invitation"), do: "This invitation is no longer available."
  defp message("identifier_mismatch"), do: "This invitation does not match the registration."
  defp message("already_claimed"), do: "Somebody has already set this instance up."
  defp message("ceremony_cancelled"), do: "The passkey prompt was dismissed or timed out."
  defp message("already_enrolled"), do: "That passkey is already registered."
  defp message("no_challenge"), do: "That registration is no longer available. Start again."
  defp message(_other), do: "Registration could not finish. Please try again."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <p :if={@invitation}>
        The account will be called <strong>{@invitation.username}</strong>.
      </p>

      <div :if={is_nil(@invitation)} class="alert alert-error">
        <span>This invitation has been used already, or it has expired.</span>
      </div>

      <div :if={@error} class="alert alert-error">{@error}</div>

      <.button :if={@invitation} phx-click="accept" variant="primary">
        Accept with a passkey
      </.button>

      <div
        id="passkey"
        phx-hook="Ithibati.Web.Hooks.PasskeyCeremony"
        data-registration-challenge-url={~p"/auth/registration/challenge"}
        data-registration-url={~p"/auth/registration"}
        data-authentication-challenge-url={~p"/auth/authentication/challenge"}
        data-authentication-url={~p"/auth/authentication"}
        data-recovery-url={~p"/auth/recovery"}
      >
      </div>
    </Layouts.app>
    """
  end
end
```

The page sends the token with `ithibati:register`; the hook forwards it to both registration
endpoints. It displays the invitation's identifier without offering to change it.

The fallback above covers other failures. For a richer interface, share a message module
between this page and sign-in and cover the library codes listed in
[Handling failures](ceremonies.md#handling-failures).

## 5. Update the sign-in page

The public page should offer registration only while the instance needs its first account.
In `MyAppWeb.SignInLive`, alias `Ithibati.Identity.Instance` and replace `mount/3` with:

```elixir
@impl true
def mount(_params, _session, socket),
  do: {:ok, assign(socket, username: "", error: nil, setup: Instance.needs_setup?())}
```

Add `:if={@setup}` to the username registration form:

```heex
<form :if={@setup} phx-change="validate" phx-submit="register">
```

Keep the sign-in button, recovery form and hook outside that conditional form. Add these
clauses before the existing catch-all `message/1` clause:

```elixir
defp message("already_claimed"), do: "Somebody has already set this instance up."
defp message("invitation_unknown"), do: "Registration now needs a valid invitation link."
defp message("invalid_invitation"), do: "This invitation is no longer available."
defp message("identifier_mismatch"), do: "This invitation does not match the registration."
```

The page's `setup` assign controls presentation. The transaction remains the authority when
another person claims the instance while the page is open.

## 6. Issue and deliver a link

Create invitations from an application action restricted to accounts allowed to invite others.
For a first development check, run this in `iex -S mix` after claiming the instance:

```elixir
{:ok, invitation} =
  %MyApp.Accounts.Invitation{}
  |> MyApp.Accounts.Invitation.changeset(%{"username" => "second_person"}, days: 14)
  |> MyApp.Repo.insert()

MyAppWeb.Endpoint.url() <> "/invite/" <> invitation.token
```

The returned struct carries the plaintext `token`; a later database read does not recover it.
Deliver the link to its intended recipient. Ithibati does not send mail.

An invitation is a bearer secret: whoever holds the link can accept it. In an application keyed
by email, mailing the token to that address can form the application's address-verification
flow, because acceptance binds the account to the invitation's identifier. The token alone does
not establish how its current holder obtained the link.

## 7. Check the flow

Run `mix ithibati.doctor`, then try this on a fresh development instance:

1. Open `/` and create the first account.
2. Sign out. The public page should no longer offer open registration.
3. Create an invitation through the console or your authorized invitation action.
4. Open the link and register its account with a passkey.
5. Save the codes and confirm access to `/inside`.
6. Open the same link again. It should be unavailable.

The bootstrap claim survives deletion of the account that made it. Use a fresh development
database for another first-claim walkthrough; deleting an account is not a setup reset.

## Composing additional application steps

The account insertion comes before `Instance.claim/2`, `Invitations.accept/3` or
`Grant.with_key_and_codes/3`. Each reads the account from the `:account` step; pass
`account: :person` if your insertion uses another name.

Put invitation acceptance, bootstrap claims and application steps that can refuse before the
grant. A failed `Ecto.Multi` result can contain earlier step results, including plaintext
recovery codes, so do not log the whole tuple.

For acceptance outside a WebAuthn ceremony, `Invitations.account_attrs/1` supplies the
invitation's identifier for account creation. In a ceremony, continue using the approved subject
as the handler above does.

If your transaction also updates another singleton row, acquire it and the bootstrap row in a
consistent order throughout the application and its fixtures to avoid deadlocks.

## Housekeeping

`Invitations.expired/0` returns expired, unaccepted invitations. `Invitations.delete_expired/0`
deletes them and returns the count. Ithibati schedules no cleanup job; expired links are refused
whether or not the rows have been removed.
