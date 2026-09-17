# Invitations, and the first account

[Getting started](getting_started.md) built an application anybody can register with. This page
closes it: the first person claims the instance, and everybody after them needs a link somebody
inside wrote. It picks up from there, so each step below says what changes against the
application you already have.

Two problems, one question. Who is allowed to become an account. Ithibati answers it
without owning the table either answer lives in.

One thing before you start, if your handler predates the recovery route:
[`recovered/3`](`c:Ithibati.Web.Handler.recovered/3`) is a
required callback now, and the compiler will say so. [Recovery
codes](recovery.md#signing-in-with-one) has the two clauses it needs.

## 1. The invitation schema

New file, and arranged exactly like your account schema: you own the table, Ithibati owns what
has to be true about it. Declare it, then add whatever the invitation grants.

```elixir
defmodule MyApp.Accounts.Invitation do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.Invitation

  use Invitation, identifier: :username, format: Identifier.username_format()

  schema "invitations" do
    ithibati_invitation()

    # What the invitation grants is yours, and nothing here needs one: this page is about the
    # flow. A `field :role, Ecto.Enum, values: [:admin, :author]` would go here, with `:role`
    # added to the `cast` below and a column for it in the migration.

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(invitation, attrs, opts \\ []) do
    invitation_changeset(invitation, attrs, opts)
  end
end
```

[`ithibati_invitation/0`](`Ithibati.Schema.Invitation.ithibati_invitation/0`) adds the invitee's
identifier, `token_hash`, `expires_at`, `accepted_at`
and a virtual `:token`. Ithibati mints the secret and hands it back through that virtual field:
after the insert, `invitation.token` is the only copy there will ever be, and the row holds its
sha256.

`invitation_changeset/3` takes `days:`, which defaults to seven for a new invitation. Pass it to
an existing invitation to extend it, and the link you already sent keeps working.

The identifier has to be the same field your account schema is identified by, and Ithibati
refuses the pair when it is not. An address that already has an account is refused as you write
the invitation. Treat that as advice and not a guarantee, because the guarantee is the
unique index on your accounts table.

## 2. The table, and one line of configuration

Tell Ithibati the schema exists first, because the migration below reads it:

```elixir
config :ithibati, invitation_schema: MyApp.Accounts.Invitation
```

Without that key none of what follows is reachable, which is what makes invitations optional.

Then the table. It is yours to create, and the columns Ithibati reads come from Ithibati, so
that they cannot disagree with the schema that declares them:

```elixir
defmodule MyApp.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  def change do
    create table(:invitations) do
      Ithibati.Migration.invitation_columns(version: 1)

      # Whatever the invitation grants goes here — a role, a team, a tenant. That is the reason
      # this table is yours.

      timestamps(type: :utc_datetime_usec)
    end
  end
end
```

That call adds exactly four columns, and nothing else about the table is its business:

| | | |
| --- | --- | --- |
| the identifier your schema declares | `:string` | `null: false` |
| `:token_hash` | `:binary` | `null: false` |
| `:expires_at` | `:utc_datetime_usec` | `null: false` |
| `:accepted_at` | `:utc_datetime_usec` | nullable. `NULL` is what "not accepted yet" means, and [`Invitations.fetch/1`](`Ithibati.Identity.Invitations.fetch/1`) reads it that way |

The virtual `:token` the schema declares is not among them, because the secret is never stored.

The identifier column is `:string`, and there is no option for that yet. If your accounts
If your accounts identifier is `citext`, a shape
[Getting started](getting_started.md#3-the-account-schema) says most applications do not need,
write the four `add` lines out instead, so the two tables agree
about case on the field Ithibati insists is the same field.

`version:` is required for the same reason [`up/1`](`Ithibati.Migration.up/1`) requires it: a
migration is a record of what
was built, and an unpinned call would expand against whichever release happens to be installed
the next time somebody sets up a database from scratch.

Writing the four `add` lines out instead is fine, and an existing invitations table needs no
migration at all. Ithibati checks the columns and their types before it builds anything either
way, so a `token_hash` written `:string` is refused at `mix ecto.migrate` and not at the
first invitation.

### If Ithibati's migration has already run

Which it has, if you followed [Getting started](getting_started.md). That changes one
thing. The unique index on `token_hash` is created by `Ithibati.Migration.up/1`, which is
recorded as applied and will not run again. Add it in the same migration as the table:

```elixir
def change do
  create table(:invitations) do
    Ithibati.Migration.invitation_columns(version: 1)

    timestamps(type: :utc_datetime_usec)
  end

  Ithibati.Migration.invitation_index(version: 1)
end
```

Safe either way: it creates the index only if it is not there, and so does `up/1`, so a database
rebuilt from scratch replays both without colliding. Leave it out and you get a table whose
bearer token has no uniqueness guarantee. `mix ithibati.doctor` reports that one, and it is the
only thing that will.

## 3. The first account

Nobody can invite the first person, so that registration is a one-time page instead.
`Ithibati.Identity.Instance.claim/2` is the step that makes it one:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:account, User.changeset(%User{}, %{username: username}))
|> Ithibati.Identity.Instance.claim()
|> Ithibati.Identity.Grant.with_key_and_codes(key_attrs)
|> MyApp.Repo.transaction()
```

None of Ithibati's three fragments reads another's output. `claim/2`,
[`accept/3`](`Ithibati.Identity.Invitations.accept/3`) and
[`with_key_and_codes/3`](`Ithibati.Identity.Grant.with_key_and_codes/3`) all read the step that
created the account, so only that step has to
come first. But **put whatever can refuse before `with_key_and_codes/3`**, which is why the
claim is above it here. Two reasons, and the second is the one that is easy to miss: a
transaction that was never going to commit should not mint a batch of recovery codes on its way
to being rolled back, and the error tuple a failure hands you,
`{:error, step, value, changes_so_far}`, still carries those codes in plaintext. Log that tuple
whole and they are in your logs, for an account that does not exist.

The second person to try gets `{:error, :bootstrap, :already_claimed, _}` and leaves no account
behind, because the whole transaction rolls back. That is what makes the guarantee hold when two
people register in the same second instead of one after the other.

> #### The bootstrap row is a singleton, and yours may be one too {: .info}
>
> What makes that guarantee hold is a unique index. `ithibati_bootstrap` has one on a boolean
> column that defaults to `true`, so at most one row can claim the instance, and two transactions
> that both claim block on it.
>
> That also puts a deadlock within reach of any application holding a singleton of its own. Two
> transactions taking the two rows in opposite orders each wait on what the other holds, and
> Postgres kills one of them with `40P01`. It was reported from a test suite that hit it on
> roughly one seed in three, in a test that touched neither row. The symptom is a long way from
> the cause and reads like flakiness.
>
> Write to the two in the same order everywhere, fixtures included. Which order does not matter.
> Having one does.

[`Instance.needs_setup?/0`](`Ithibati.Identity.Instance.needs_setup?/0`) is the question your
registration page asks to decide which of the two
it is showing.

## 4. Accepting an invitation

Accepting composes into your own transaction, so the account and what it is a member of arrive
together or not at all:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:account, User.changeset(%User{}, Invitations.account_attrs(invitation)))
|> Ithibati.Identity.Invitations.accept(invitation)
|> Ithibati.Identity.Grant.with_key_and_codes(key_attrs)
|> Ecto.Multi.insert(:membership, fn %{account: account, invitation: accepted} -> … end)
|> MyApp.Repo.transaction()
```

`accept/3` goes after the step that creates the account. That is the same rule as the other two,
and the only ordering rule there is. It checks that the account being created carries the
identifier the invitation was addressed to and returns `{:error, :identifier_mismatch}` if it
does not, so an acceptance form that lets people correct their address cannot hand the
invitation to somebody else. Name the step with `account:` if yours is not called `:account`.

That check is also what makes an invitation an address verification, for an application that
mails the link itself. The account can only come into existence under the address the link went
to, so whoever holds it read mail sent there. Ithibati has no separate confirm-by-email loop
because this is one, and

says what it does not cover.

## 5. The handler, now with two ways in

Your handler changes shape, and `SignInLive` and the router change with it. Step 6 covers
those. Here, [`registration_subject/2`](`c:Ithibati.Web.Handler.registration_subject/2`) decides
which of the two registrations is happening and
[`register/4`](`c:Ithibati.Web.Handler.register/4`) builds the matching transaction.

Add two aliases first, since both branches use them:

```elixir
alias Ithibati.Identity.Instance
alias Ithibati.Identity.Invitations
```

```elixir
@impl true
def registration_subject(_conn, params) do
  if Instance.needs_setup?(),
    do: first_account(params),
    else: invited(params["token"])
end

defp invited(token) when is_binary(token) do
  case Invitations.fetch(token) do
    nil -> {:error, :invitation_unknown}
    invitation -> {:ok, invitation.username}
  end
end

defp invited(_missing), do: {:error, :invitation_required}

# The branch you already had, now reached only while the instance is unclaimed.
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
```

`Invitations.fetch/1` returns the pending, unexpired invitation a token opens, or `nil`. Answer
an unknown token and a missing one the same way: a token that opens nothing should not be
distinguishable from no token at all.

`invitation.username` is this page's identifier, not a fixed name. It is whatever your schemas
declare, and Ithibati refuses the pair if the two disagree.

`register/4` is rewritten, not added to. The one you have builds its `Ecto.Multi` inline
and pipes it straight into `Repo.transaction/1`; there is no seam to compose onto, so the
transaction moves into a function of its own and `register/4` picks between two of them. Its
fourth argument stops being `_params`, because that is where the token arrives:

```elixir
@impl true
def register(conn, key_attrs, username, params) do
  username
  |> acceptance(params["token"], key_attrs)
  |> Repo.transaction()
  |> case do
    # …unchanged from here: the same three clauses you already wrote.
  end
end
```

And the transaction each way in needs:

```elixir
defp acceptance(username, token, key_attrs) do
  if Instance.needs_setup?() do
    Multi.new()
    |> Multi.insert(:account, User.changeset(%User{}, %{"username" => username}))
    |> Instance.claim()
    |> Grant.with_key_and_codes(key_attrs)
  else
    Multi.new()
    |> Multi.insert(:account, User.changeset(%User{}, %{"username" => username}))
    |> Invitations.accept(Invitations.fetch(token))
    |> Grant.with_key_and_codes(key_attrs)
  end
end
```

> #### Build the account from `username`, not from the invitation {: .warning}
>
> Both branches insert the identifier `registration_subject/2` approved, which `register/4`
> receives as its third argument. That is not a stylistic choice.
>
> The browser posts the whole body again at `/registration`, so `params["token"]` in the second
> request need not be the token that was approved in the first. Building the account from
> `Invitations.account_attrs(that_invitation)` would create it under whatever identifier the
> *second* token names, and `accept/3`'s mismatch check would compare that invitation against
> an account made from it, agree, and pass.
>
> Taking the identifier from `username` closes it: the account carries the approved identifier,
> so a token swapped in between the two requests fails `accept/3` with
> `{:error, :identifier_mismatch}`. `c:Ithibati.Web.Handler.register/4` says the same thing in
> one sentence, and it is the reason the subject is carried instead of re-read.

[`Invitations.account_attrs/1`](`Ithibati.Identity.Invitations.account_attrs/1`) is still how you
read an invitation's identifier when you are
composing acceptance somewhere that did *not* go through a ceremony, such as a console or an
admin action. In those there is no approved subject to prefer.

`Invitations.account_attrs/1` hands you the identifier the invitation was addressed to, so the
account is created with the address somebody was invited at, never one typed into the form.

## 6. The page an invitation link opens

Step 5 reads `params["token"]`, and nothing has put one there yet. The token travels the way the
username does: the LiveView pushes it, the hook forwards the payload to both endpoints, and it
arrives in `registration_subject/2`'s `params` and in `register/4`'s fourth argument.

A route of your own:

```elixir
live "/invite/:token", InviteLive
```

And the page behind it. It shows the identifier the invitation was addressed to and does not
offer to change it. `accept/3` checks that the account being created carries that identifier,
so a field here would produce a refusal further down and, until somebody noticed, a form that
looks like it hands an invitation to whoever fills it in:

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

  # Only the four this page can reach that the others cannot. Everything the library itself
  # sends needs a clause too, and the shape of that is in Getting started.
  defp message("invitation_unknown"), do: "This invitation has been used, or it has expired."
  defp message("invitation_required"), do: "This page needs an invitation link."
  defp message("identifier_mismatch"), do: "That invitation was written to somebody else."
  defp message("already_claimed"), do: "Somebody has already set this instance up."
  defp message(other), do: "Something went wrong: #{other}"

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

Four failure codes are new on this page: `invitation_unknown`, `invitation_required`,
`identifier_mismatch` and `already_claimed`. The `message/1` in your `SignInLive` from
[Getting started](getting_started.md) does not know them yet. Without them a second person
racing the setup page reads "Something went wrong: already_claimed".

Two pages needing the same sentences is the moment to move them out of both. The invitation-only
example does that, in `IthibatiInvitesWeb.CeremonyMessages`, with a test holding it to
[`Ithibati.Ceremony.codes/0`](`Ithibati.Ceremony.codes/0`) so that a word a release adds arrives
as a failing suite.

### And the page that is now wrong

`SignInLive` from [Getting started](getting_started.md) has a username form whose submit
registers an account. Once this instance is claimed, that form cannot work any more. Every
submission ends in `{:error, :invitation_required}`, while the field and the button go on
looking as though they should. It is the same page in two states, so ask which one you are in:

```elixir
@impl true
def mount(_params, _session, socket),
  do: {:ok, assign(socket, username: "", error: nil, setup: Instance.needs_setup?())}
```

and render the form only `:if={@setup}`, with the sign-in button and the recovery-code form
outside it. Nobody registers on that page afterwards; they arrive on an invitation link
instead.

## 7. Writing an invitation

An ordinary insert through your own schema, from a page only signed-in accounts can reach. The
secret comes back on the struct and never again:

```elixir
{:ok, invitation} =
  %MyApp.Accounts.Invitation{}
  |> MyApp.Accounts.Invitation.changeset(%{"username" => username}, days: 14)
  |> MyApp.Repo.insert()

invitation.token
```

Getting that token to the right person is your job. Nothing here sends mail, so the link is a
bearer secret: whoever opens it accepts the invitation.

is the argument, and it is also where address verification is described as planned and not
refused.

## Checking it

`mix ithibati.doctor` gained a question with the invitation table: whether it is there, and
whether `token_hash` carries the unique index. That is the one check nothing else can make for
an application that turned invitations on later, because `up/1` will not run again.

Then the loop, the way [Getting started](getting_started.md) ends with one. On an empty
instance: open the registration page, claim it with a passkey, and watch `needs_setup?/0` turn
false. Write an invitation from a signed-in session, open its link in a private window, accept
it with a second passkey, and you have two accounts and a spent invitation. Open the same link
again. It reports the same refusal as a token nobody holds.

> #### How do you test the claim path twice? {: .info}
>
> You cannot, without undoing it: `Ithibati.Identity.Instance.needs_setup?/0` is false forever
> once the instance is claimed, and there is no reset. In development, delete the row —
> `MyApp.Repo.delete_all(Ithibati.Bootstrap)` in `iex -S mix`, and the setup page comes back.
>
> That is one of Ithibati's own tables, so `Ithibati.Credo.NoDirectTableAccess` will report it
> if you leave it in a file. That is the right answer: this belongs in a console, not in your
> `seeds.exs`.

## Housekeeping

[`expired/0`](`Ithibati.Identity.Invitations.expired/0`) and
[`delete_expired/0`](`Ithibati.Identity.Invitations.delete_expired/0`) are there for a sweeper of
your own. Ithibati schedules
nothing and never deletes on its own.

The table is yours with Ithibati's invariants on it, not a table Ithibati owns, for the
same reason the accounts table is: what an invitation grants is the application's and the
library must not assume a column it did not put there. The bootstrap row is a table of
Ithibati's for the mirror-image reason. It records something about the instance, not about an
account.
