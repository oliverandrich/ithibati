# Invitations and the first account

Adapt the application from [Getting started](getting_started.md) so the first account claims
the instance and subsequent accounts need an invitation. Protect that first claim with an
operator-issued code before exposing the application publicly. Your application owns the invitation
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
      Ithibati.Migration.invitation_columns(version: 4)
      timestamps(type: :utc_datetime_usec)
    end

    Ithibati.Migration.invitation_index(version: 4)
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
| Your configured identifier | `:string` by default; override with `type:` | No |
| `token_hash` | `:binary` | No |
| `expires_at` | `:utc_datetime_usec` | No |
| `accepted_at` | `:utc_datetime_usec` | Yes |
| `invited_by_id` | Your account key, from version 4 | Yes |

The plaintext token is virtual and is not stored. Pin the version the way `up/1` is pinned: a
migration written today says `version: 4`, and one written before that goes on producing what it
produced then. For a table created before version 4, add the inviter with
`invitation_inviter_column/1` rather than editing the migration that made it:

```elixir
def up do
  alter table(:invitations) do
    Ithibati.Migration.invitation_inviter_column(version: 4)
  end

  Ithibati.Migration.up(from: 3, version: 4)
end
```

The order in that migration is not free. `up/1` flushes the queued statements before it checks the
table, so an `alter` written above it has already run; the same `alter` written below it has not,
and `up/1` refuses a table whose inviter column is still missing.

`mix ithibati.doctor` asks the same question of a database nobody is migrating. An installation
that lifted the library and wrote no new migration compiles, migrates and starts; the column it
lacks is first missed at an invitation.

For an existing table, supply the same columns and required index. Most applications can keep `:string`: both changesets trim and
lowercase identifiers. If you deliberately use PostgreSQL `citext`, for example to handle
writes outside the changesets, select it explicitly:

```elixir
Ithibati.Migration.invitation_columns(version: 4, type: :citext)
```

Install the `citext` extension before this migration; the helper does not create it. The
identifier remains a `:string` field in the Ecto schema. `type:` changes only the identifier
column, not the token or timestamps.

The type must be resolvable by the migration's database connection. If the extension lives
outside its `search_path`, qualify the type, for example `type: :"extensions.citext"`, or
configure the connection's `search_path` to include that schema.

Migration and doctor checks do not require identical account and invitation identifier types.
Choose their comparison semantics deliberately. For an existing table, use a new application
migration to alter its column; do not edit a migration that has already run.

### Protect the first account claim

The one-time bootstrap row prevents a *second* claim; by itself it does not prove that the first
visitor is the operator. Configure the protected mode before serving an unclaimed instance:

```elixir
config :ithibati, initial_claim: :operator_code
```

The [getting-started migration](getting_started.md#4-the-migration) at version 3 already creates
the operator-code digest table. If your application has only applied version 2, add a **new**
application migration with `Ithibati.Migration.up(from: 2, version: 3)` and the matching `down/1`.
Apply it explicitly before issuing a code. Never edit an applied migration.

`Instance.issue_code/0` issues a fresh 32-byte random code and returns its plaintext once.
Ithibati stores only its SHA-256 digest in the database. Expose the operation through an application-owned
operator command, such as the `mix ithibati_invites.setup_code` task in the
[invitation-only example](https://github.com/oliverandrich/ithibati/tree/main/examples/invitation_only). Print the returned code to the
operator's terminal, not an HTTP response or a startup log. Running the command again rotates the
code and revokes earlier authorization. After a successful claim it returns
`{:error, :already_claimed}`, and under any mode but `:operator_code` it returns
`{:error, :claim_is_open}` — an instance that leaves its claim open has no code to issue.
The application chooses a rate limit for its public code form.

`Instance.authorize_code/1` checks the code and returns a short-lived proof for the browser
session, `{:error, :invalid_setup_code}` when the code does not check out, or
`{:error, :claim_is_open}` under any mode but `:operator_code`. The application calls
`Instance.authorized?/1` before starting a passkey challenge and
passes that same proof to `Instance.claim/2` at completion. The claim atomically consumes it with
the account insert and bootstrap claim. A direct request without a proof therefore fails even if
the page hid its form. In protected mode, `Instance.claim/2` refuses missing authorization.

## 3. Replace the registration handler

Replace `lib/my_app_web/auth.ex` with this handler. It retains authentication and recovery from
the walkthrough and adds the two registration paths:

```elixir
defmodule MyAppWeb.Auth do
  @behaviour Ithibati.Web.Handler

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [get_session: 2, put_session: 3]

  alias Ecto.Multi
  alias Ithibati.Identity.Grant
  alias Ithibati.Identity.Instance
  alias Ithibati.Identity.Invitations
  alias Ithibati.Web.Gate
  alias MyApp.Accounts.User
  alias MyApp.Repo

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
    registration_multi(username, conn, params["token"], key_attrs)
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

  defp registration_multi(username, conn, token, key_attrs) do
    account = User.changeset(%User{}, %{"username" => username})

    if Instance.needs_setup?() do
      Multi.new()
      |> Multi.insert(:account, account)
      |> Instance.claim(authorization: get_session(conn, :initial_claim_authorization))
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
A missing, expired or rotated proof returns `:setup_authorization_required` under the same step.

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
def mount(_params, session, socket) do
  setup = Instance.needs_setup?()

  {:ok,
   assign(socket,
     username: "",
     error: nil,
     setup: setup,
     setup_authorized?: setup and Instance.authorized?(session["initial_claim_authorization"])
   )}
end
```

Show a regular, CSRF-protected form that posts the operator code to an application controller
while `@setup and not @setup_authorized?`. Only offer the username registration form when
`@setup and @setup_authorized?`:

```heex
<.form :if={@setup and not @setup_authorized?} for={%{}} action={~p"/setup-code"}>
  <.input name="setup_code" type="password" value="" label="Operator code" required />
  <.button>Continue</.button>
</.form>
```

Add `:if={@setup and @setup_authorized?}` to the existing username registration form.
Add `post "/setup-code", SetupController, :authorize` to the CSRF-protected browser scope. The
controller calls `Instance.authorize_code/1`, stores the returned proof under
`:initial_claim_authorization` in the session, sets `Cache-Control: no-store`, and redirects
back to the page. The
[invitation-only example](https://github.com/oliverandrich/ithibati/tree/main/examples/invitation_only)
has the complete controller. Include `"setup_code"` in Phoenix's `:filter_parameters` so request
logs hide it. Apply an application or edge rate limit to this public POST.

Keep the sign-in button, recovery form and hook outside that conditional form. Add these
clauses before the existing catch-all `message/1` clause:

```elixir
defp message("already_claimed"), do: "Somebody has already set this instance up."
defp message("setup_authorization_required"), do: "Enter the current operator code first."
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
Deliver the link to its intended recipient, manually or through the optional
[email delivery integration](#email-delivery).

An invitation is a bearer secret: whoever holds the link can accept it. In an application keyed
by email, mailing the token to that address can form the application's address-verification
flow, because acceptance binds the account to the invitation's identifier. The token alone does
not establish how its current holder obtained the link.

## 7. Check the flow

Run `mix ithibati.doctor`, then try this on a fresh development instance:

1. Issue a code with the application-owned operator command, then open `/` and enter it.
2. Create the first account with a passkey.
3. Sign out. The public page should no longer offer open registration.
4. Create an invitation through the console or your authorized invitation action.
5. Open the link and register its account with a passkey.
6. Save the codes and confirm access to `/inside`.
7. Open the same link again. It should be unavailable.

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

`Invitations.expired_query/0` is the predicate both of those use, for an application with sites,
roles or an order of its own to narrow — the same arrangement as `pending_query/0` below. Reach
for the query rather than the list whenever the answer has to be scoped: a `where` written again
here is a second opinion about when an invitation has run out, and the one that deletes rows is
the other one.

```elixir
import Ecto.Query

from(i in Ithibati.Identity.Invitations.expired_query(), where: i.site_id == ^site.id)
|> MyApp.Repo.all()
```

## Showing and withdrawing pending invitations

`Invitations.pending_query/0` returns the query that finds unaccepted, unexpired invitations —
the same predicate `fetch/1` applies to a token. Narrow it with whatever the application's own
columns call for, then run it with your repo:

```elixir
import Ecto.Query

from(i in Ithibati.Identity.Invitations.pending_query(),
  where: i.site_id == ^site.id,
  order_by: [asc: i.email],
  preload: [:invited_by]
)
|> MyApp.Repo.all()
```

`Invitations.pending/0` returns all of them for an application that needs no scoping.

An invitation also carries `invited_by_id`. The changeset does not cast it: who is inviting is
known to the caller and to nobody else, so an application that hands a form's params straight
through cannot let a visitor name whoever they like. Put it there yourself:

```elixir
%MyApp.Accounts.Invitation{}
|> MyApp.Accounts.Invitation.changeset(attrs)
|> Ecto.Changeset.put_change(:invited_by_id, inviter.id)
```

It is nullable: rows written before the column existed have none.

> #### The column, not the association {: .info}
>
> Ithibati declares `invited_by_id` and stops there. Write the association yourself when you
> want one:
>
> ```elixir
> schema "invitations" do
>   ithibati_invitation()
>   belongs_to :invited_by, MyApp.Accounts.User, define_field: false
> end
> ```
>
> Declaring it in the macro would need the account schema while your invitation schema compiles,
> which would pin `user_schema` to compile time — a third setting frozen at build, beside
> `users_key_type` and `table_prefix`. It would also stop compiling for any application that had
> already written the association by hand, because Ecto refuses a field declared twice.

`Invitations.withdraw/1` takes one back and returns `{:ok, invitation}`, or
`{:error, :already_accepted}` when the row was accepted or is no longer there. It rechecks the
acceptance inside its delete, so a withdrawal cannot remove an invitation that is being redeemed
at that moment. Take the list and the withdrawal from the same predicate: a page that can show
an invitation it cannot withdraw, or withdraw one it does not show, is the same bug twice.


## Email delivery

`Ithibati.InvitationMail` sends an **existing link** through two application functions. It does
not create a second kind of invitation. Keep the schema, token generation, expiry and acceptance
flow above, and call delivery after the invitation has been persisted successfully.

For a Phoenix application with an existing Swoosh mailer, create
`lib/my_app/invitation_email.ex`:

```elixir
defmodule MyApp.InvitationEmail do
  import Swoosh.Email

  def content(url, _context) do
    {:ok, %{subject: "Your invitation", text: "Complete your registration: #{url}"}}
  end

  def deliver(recipient, content) do
    new()
    |> to(recipient)
    |> from({"My application", "invites@example.com"})
    |> subject(content.subject)
    |> text_body(content.text)
    |> html_body(Map.get(content, :html))
    |> MyApp.Mailer.deliver()
  end
end
```

Configure these functions:

```elixir
config :ithibati, :invitation_mail,
  enabled: true,
  content: &MyApp.InvitationEmail.content/2,
  deliver: &MyApp.InvitationEmail.deliver/2
```

The content callback receives the full URL and optional `context:` (default `%{}`). Return
`{:ok, %{subject: subject, text: text}}` or include `html: html` for a multipart message. Subject
and text must be non-empty strings. The callback can render application templates and handle
localization; escape dynamic values in HTML. MJML and other template tools can live behind this
callback, without becoming dependencies of Ithibati. The delivery callback receives the recipient
and the content map, and returns `{:ok, receipt}` or `{:error, reason}`. A mailer other than Swoosh
works through the same contract.

An authorized admin action can pass the link it already generated:

```elixir
url = MyAppWeb.Endpoint.url() <> "/invite/" <> invitation.token
Ithibati.InvitationMail.deliver("recipient@example.com", url)
```

Use a trusted endpoint URL, not a request-supplied host. In the email registration scenario,
the email address is both the account identifier and the recipient address. Send to the same
normalized email stored on the invitation; do not collect a second address. The username-based
example in this guide instead supplies a separate delivery address because a username is not a
mailbox. Delivery validates the address's shape using
`Ithibati.Schema.Identifier.email_format/0`, not its existence. Following a bearer link proves
possession of that link; sending a message alone does not verify mailbox ownership, and a
forwarded link can be used by its holder. This API adds no verified-email field to an account.

### Open registration through email

Keep public registration policy in the application. When public registration **and** mail
sending are enabled in the email registration scenario, the initial form collects one email
address. That address is the identifier on both the invitation and the eventual account, and
also the mail recipient. The application creates an invitation through its existing schema and
repo, then calls `Ithibati.InvitationMail.deliver/2` with the invitation's normalized email and
the resulting link. Do not start a passkey ceremony at
this point. The email opens the existing invitation page, whose handler requires a valid token
at both the challenge and completion steps and accepts it in the account transaction.

See the [runnable email-registration example](https://github.com/oliverandrich/ithibati/tree/main/examples/email_registration).
`IthibatiEmail.Registration` creates and sends invitations, `IthibatiEmail.InvitationEmail`
connects to its Swoosh mailer, and `IthibatiEmailWeb.SignInLive` requests the link automatically.
There is one email field, and even the first account requires a link. The development mailbox
at `/dev/mailbox` lets you inspect the message and follow its link without real email delivery.

The [invitation-only example](https://github.com/oliverandrich/ithibati/tree/main/examples/invitation_only)
uses usernames and a separate first-instance bootstrap. The ordinary
[open-registration example](https://github.com/oliverandrich/ithibati/tree/main/examples/open_registration)
continues to demonstrate registration without email.

Without mail configuration, delivery is disabled and existing registration handlers continue to
work as written. Do not silently bypass a required invitation when sending fails. Give public
requests a neutral response regardless of whether an identifier already exists, and apply rate
limits per source and recipient before issuing invitations. A generic response does not by
itself remove timing differences. Authorization for admin actions remains in the application.

### Transactions, failures and retries

Call delivery only after the **outermost** invitation transaction commits. Calls inside the
configured repo's transaction return `{:error, :transaction_in_progress}` before rendering or
sending. Delivery does not enqueue work for later and cannot inspect transactions in other
processes or repos; the caller must ensure the link refers to a committed invitation.

A successful send returns `{:ok, receipt}`; disabled delivery returns `{:ok, :disabled}`.
Input/configuration errors are `{:error, :invalid_recipient}`, `{:error, :invalid_url}` or
`{:error, :invalid_configuration}`. Callback errors are tagged as `{:error, {:content, reason}}`
or `{:error, {:delivery, reason}}`; a malformed result uses `:invalid_result` as the reason.
Callback exceptions propagate as programming errors. Do not log complete callback failures,
content maps or URLs if they contain secrets or recipient data.

Rendering or delivery failure does not undo an already committed invitation. Retry with the
same URL while it is still held in memory. A transport failure can be ambiguous and a retry
may send a duplicate. Once the plaintext token is lost, a database read cannot recover it:
issue another invitation through the existing schema flow. If replacement should invalidate
older invitations, revoke them in application code; creating a new invitation does not do that
automatically. Existing links remain subject to their expiry and single-use acceptance checks.
No plaintext-token storage, queue or scheduling service is introduced by this integration.
