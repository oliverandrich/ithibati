# Ithibati

Passkey authentication for Elixir applications — accounts, WebAuthn credentials, recovery codes and
revocable tokens — without an opinion about what an account may do. The optional web half is for
Phoenix.

Swahili, *ithibati*: proof, attestation.

> **Status: nothing is released and nothing works yet.** See [CHANGELOG.md](CHANGELOG.md).

## What it is

Most authentication libraries answer two questions at once: *who is this* and *what may they do*.
The second answer is where every application differs — sites, tenants, teams, roles, invitations —
and it is why the first answer so rarely gets reused.

Ithibati will answer only the first:

- passkey registration and authentication (WebAuthn, via [`wax_`](https://hex.pm/packages/wax_)),
  including the bootstrap case of the very first account
- recovery codes, single-use, for the day a passkey is gone
- revocable server-side tokens — a session behind a cookie, a device token behind a bearer header,
  the same row with a different context
- the changeset pieces and the composable `Ecto.Multi` fragments to hang your own steps on

Your application keeps its own `users` table, its own roles and — since every application this is
for is invite-only — its own invitations table, and composes the grant into one transaction with the
library's half.

## Two ways to let people in

**Open:** anyone who reaches your registration page makes a passkey and an account. **Invitation
only:** somebody already signed in writes an invitation, and nobody else gets one. You decide which
by whether you offer a registration path to somebody who is not signed in; the library ships both
halves and forbids neither.

Neither proves that the person owns the address they were named by, and nothing here sends mail — so
the invitation token is a bearer secret, and delivering it to the right person is yours to do.
[Decision 10](docs/design.md#10-open-registration-and-invitation-only-and-neither-proves-an-address)
is the whole of the reasoning, including what a later release might add.

## Two applications you can run

Everything below is also written out as something that compiles and runs — which is where to look
when a paragraph here and your editor disagree. There are two, one for each way of letting people
in. The decision itself is a single function in each; the invitation machinery behind it — a
table, a schema, an acceptance page — exists only in the second:

- [`examples/open_registration`](https://github.com/oliverandrich/ithibati/tree/main/examples/open_registration)
  — anybody who reaches the page picks a username and makes a passkey.
- [`examples/invitation_only`](https://github.com/oliverandrich/ithibati/tree/main/examples/invitation_only)
  — the first account claims the instance, and everybody after it arrives on a link somebody
  signed in wrote.

Both use usernames, because a username is the identifier that needs nothing sent to it; the
[identifier section](#the-identifier-is-yours-to-choose) is where email belongs in this document. CI compiles both,
formats them, builds their assets, runs their tests and drives them in a browser, so neither can
quietly stop working.

Links rather than directories: the examples are not in the published package, so these only resolve
on GitHub.

## What it runs on

**Elixir 1.17 or newer**, and **Postgres**. Postgres is not a default but a requirement: the
migration reads the account table's own catalogue entries to check what it is about to point a
foreign key at, and no other adapter answers those questions. CI builds both ends of the Elixir
range and both account-key types.

## The routes

Four endpoints drive the two ceremonies, wired in one call:

```elixir
pipeline :ceremony do
  # Not `["html"]`. These endpoints answer JSON, and a `:browser` pipeline would refuse the hook's
  # request with a 406 before the controller is reached.
  plug :accepts, ["json"]
  plug :fetch_session
  plug :protect_from_forgery
end

scope "/auth" do
  pipe_through :ceremony
  ithibati_routes handler: MyApp.Auth, rp_name: "MyApp"
end
```

Its own pipeline rather than your `:browser` one, and every plug in it is load-bearing. The
challenge waits in the session between the two round-trips, so something has to have fetched one.
`protect_from_forgery` is what the hook answers with the `x-csrf-token` header — a JSON body is not
exempt from it. And the format list is `json`, which is what these endpoints actually speak.

The relying party comes by default from your endpoint's configured `:url` rather than from the
connection — behind a proxy that terminates TLS those disagree, and the browser signs what it saw.

`:rp_name` is the name a passkey dialog shows. Two more options belong to a mount rather than to
this library — `:user_verification`, whether the authenticator must confirm who is holding it, and
`:seconds`, how long a challenge stays acceptable — and default to `"preferred"` and sixty.

`MyApp.Auth` implements `Ithibati.Web.Handler`, which is where the decisions this library
deliberately does not make are yours: who may start a registration, what an account is made of once
a credential verifies, and what is issued after an assertion. A session cookie is one answer; a
bearer token for an extension or a native client is another, and picking one for you would rule the
other out.

`relying_party/2` is optional. A browser served from your own URL wants the default — the
endpoint's configured `:url`, which is what the browser saw rather than what your node accepted.
The default is handed to it rather than replaced, so the usual shape adds rather than substitutes:
the same passkey has to keep working in the browser.

```elixir
def relying_party(_conn, {rp_id, origin}), do: {rp_id, [origin | @extension_origins]}
```

Implement it when the client's origin is not your URL: a native app's assertion
arrives with the origin of an associated domain, an extension's with the origin of the extension,
and one relying-party id serves all of them. Which of those you accept is your decision, so you are
asked rather than configured.

The origin may be a list, and for an extension it usually is: the same extension has a different
stable origin in each browser — `chrome-extension://<id>` and `moz-extension://<hash>` — and an
assertion carries whichever one it was made at.

**Return values chosen from a fixed set.** Reading the `origin` request header and handing it back
makes the check compare the client's claim against itself, so it matches whatever arrives: a
credential registered for your site could then be asserted from any page its holder visits. Nothing
fails when you get this wrong — not in production, not in your tests — because the origin always
"matches".

What the library does hold is the ceremony itself — and one property that is easy to lose: a
challenge is single-use, so it is spent the first time a verification is attempted, whether that
attempt succeeded or not.

## Who is signed in

`Ithibati.Web.Gate` answers that on a plain connection and in a LiveView, from one module, because
two answers that drift apart is the failure this shape exists to rule out.

```elixir
pipeline :browser do
  plug :fetch_session
  plug Ithibati.Web.Gate, :current_account
end

live_session :admin, on_mount: [{Ithibati.Web.Gate, {:require_account, to: ~p"/sign-in"}}] do
  live "/admin", AdminLive
end
```

Two modes and no others. `:current_account` assigns `@current_account`, or `nil`, and always
continues. `:require_account` refuses when there is nobody: the plug redirects when you give it
`:to` and answers `401` when you do not, which is what an API route wants; the `on_mount` requires
`:to`, because a LiveView that halts with nowhere to send a person is a dead end.

An unrecognised mode raises where it is written. A gate that listed its modes and let anything else
through would turn a typo into a page that refuses nobody — protection that never fails visibly.

`Gate.log_in(conn, account)` is what a handler's `authenticate/2` usually ends with: a session
token, stored under this library's key, after the session is renewed against fixation.
`Gate.log_out/1` revokes the token rather than merely forgetting it, so a copied cookie stops
working for new requests and new mounts — and it ends the sockets that session opened, so a
LiveView left running in another tab does not go on answering as somebody who signed out. That
second half needs two things a `mix phx.new` application already has: a `:pubsub_server` on your
endpoint, and the live socket declared with the session in its `connect_info` —

```elixir
socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [session: @session_options]]
```

— because that session is where `Phoenix.LiveView.Socket.id/1` looks. Without the pubsub server the
gate writes no socket id and says nothing, and you are back to the first half alone. Without the
`connect_info`, nothing subscribes and the broadcast reaches nobody: no error, just a socket that
outlives its session. [Decision 11](docs/design.md#11-the-gate-ends-the-sockets-a-session-opened-when-it-can) is
why it is arranged that way rather than asked of you.

Signing in clears the session, the CSRF token with it, so **the flow has to end in a full page
load**: answer from your handler with `%{redirect: …}` and the hook follows it. A page that stays
put after signing in holds a token the new session has never heard of, and its next form post is
refused. Neither is imposed — a handler issuing a bearer token for an extension calls neither, and
the gate then finds nobody, which is the right answer.

This gates *authentication* and stops there. What an account may **do** is your question, not this
library's.

## The JavaScript

The passkey ceremonies need a little client code: the browser's API wants buffers where this
library sends unpadded base64url, and it hands back a credential that has to be serialised the way
the verifications expect. That lives in `priv/static/ithibati.js`.

There are two ways to reach it, they differ in one string, and both register the same hook name.

The hook talks to the endpoints `ithibati_routes/1` generated, and it reads their paths off the
element, because you chose the scope they are mounted under:

```heex
<div
  id="sign-in"
  phx-hook="Ithibati.Web.Hooks.PasskeyCeremony"
  data-registration-challenge-url={~p"/auth/registration/challenge"}
  data-registration-url={~p"/auth/registration"}
  data-authentication-challenge-url={~p"/auth/authentication/challenge"}
  data-authentication-url={~p"/auth/authentication"}
></div>
```

Set the pair for each ceremony that element starts; a missing one is reported as
`missing_data_registration_url` rather than as a ceremony that failed.

Push `ithibati:register` or `ithibati:authenticate` from your LiveView to start a ceremony — that is
where the identity fields are and where they have been validated. The hook pushes back
`ithibati:done` with whatever your handler answered, or `ithibati:failed` with a reason. The one
answer it acts on itself is `%{redirect: …}`: a handler that sends somewhere — the page that shows
the recovery codes, say — is obeyed rather than reported. Everything
in between is a `fetch` to the endpoints rather than a LiveView event, because the sign-in ends in a
session cookie and only a controller can set one.

This is the half that runs on somebody else's machine, so it is driven rather than described. Both
example applications carry Wallaby feature tests — `test/features/` in each — that put this file in
a real browser against a real WebAuthn ceremony, including the reasons the hook distinguishes when
one does not finish. They are part of each example's own `mix test`, so CI runs them on every push.
Chromium only: the virtual authenticator is Chrome DevTools Protocol's, which is the one that hands
the page a credential real enough for `toJSON()`.

**From the package**, which always works. The specifier is bare because this library ships a
`package.json`, the same way `phoenix` and `phoenix_live_view` do, and a Phoenix 1.8 application
already has `deps` on esbuild's `NODE_PATH`:

```javascript
import {hooks as ithibatiHooks} from "ithibati"

let liveSocket = new LiveSocket("/live", Socket, {hooks: {...ithibatiHooks}})
```

**From the colocated manifest**, if you would rather LiveView kept track of it. Set
`ITHIBATI_COLOCATED_HOOKS=1` in the environment that builds your project, so that this library runs
LiveView's compiler and writes the manifest:

```javascript
import {hooks as ithibatiHooks} from "phoenix-colocated/ithibati"
```

Then build this library again — `mix deps.compile ithibati --force`. Mix does not rebuild a
dependency because an environment variable changed, and the manifest is only written while
compiling, so without that step the import resolves to nothing and the bundler says so without
saying why.

If you are not using LiveView, import `register` and `authenticate` from the same package instead
of the hook. They take the options this library produced, drive `navigator.credentials`, and return
what the verifications expect.

## Design

These decisions shape it, and [`docs/design.md`](docs/design.md) carries each one with its reasoning:

1. [The name](docs/design.md#1-the-name)
2. [The application owns the `users` table](docs/design.md#2-the-application-owns-the-users-table)
3. [`Ithibati.Identity.*` may not name another context](docs/design.md#3-ithibatiidentity-may-not-name-another-context)
4. [A grant is `Ecto.Multi` composition, not an event](docs/design.md#4-a-grant-is-ectomulti-composition-not-an-event)
5. [Non-browser clients ride on the token, not on OAuth2](docs/design.md#5-non-browser-clients-the-token-is-the-boundary-not-oauth2)
6. [No authenticator name data ships with it](docs/design.md#6-no-authenticator-name-data-ships-with-this-library)
7. [The core builds what the browser reads](docs/design.md#7-the-core-builds-what-the-browser-reads-and-which-webauthn-choices-are-whose)
8. [The second credential set refills itself](docs/design.md#8-the-second-credential-set-refills-itself)
9. [Invitations are the application's table and this library's invariants](docs/design.md#9-invitations-are-the-applications-table-and-this-librarys-invariants)
10. [Open registration and invitation-only, and neither proves an address](docs/design.md#10-open-registration-and-invitation-only-and-neither-proves-an-address)
11. [The gate ends the sockets a session opened, when it can](docs/design.md#11-the-gate-ends-the-sockets-a-session-opened-when-it-can)

## The account schema

Your application keeps its own account schema and its own table. This library adds one field — the
one you name — three associations and three functions, and nothing else:

```elixir
defmodule MyApp.Accounts.User do
  use Ecto.Schema

  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.User

  use User, identifier: :email, format: Identifier.email_format()

  import Ecto.Changeset

  schema "users" do
    ithibati_account()

    field :name, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> identifier_changeset(attrs)
    |> cast(attrs, [:name])
  end
end
```

Two patterns come with the library, and both are offered rather than imposed:
`Identifier.email_format/0` and `Identifier.username_format/0`. The second is Mastodon's rule for a
local account — letters, digits and underscores, at most thirty characters — borrowed rather than
invented, because what it leaves out is the point: dots and hyphens let `alice.smith` stand beside
`alicesmith`, and anything outside ASCII lets a Cyrillic `а` stand beside a Latin `a`.

### The identifier is yours to choose

There is no default. Pass the field an account is known by, and a pattern if you want one:

```elixir
use User, identifier: :username, format: Identifier.username_format()
use User, identifier: :handle
```

`format:` is optional, and a pattern of your own is as welcome as either of the two above —
written inline, or named, whichever reads better:

```elixir
@handle ~r/\A[a-z][a-z0-9_]{2,29}\z/

use User, identifier: :handle, format: @handle
```

The attribute has to stand above the `use` line — it is read where your module body reaches it. A
name that is not there yet, or one that is misspelled, is `nil`, and an option written as `nil` is
refused rather than quietly taken to mean the default. The same goes for `constraint_name:` and
`unique_index:` below. Only `identifier:` has to be written out: it is the field your schema
declares, and it belongs where you can read it.

`constraint_name:` and `unique_index:` concern the index on that column — see the migration below.
Values written through `identifier_changeset/2` are trimmed and lowercased, so a plain unique index refuses `AdaLovelace`
beside `adalovelace` with no functional index for you to remember — a write that bypasses the
changeset stores whatever it is given.

Why there is no default, and why the offered pattern is not RFC 5322, is in
[decision 2](docs/design.md#2-the-application-owns-the-users-table).

If a passkey dialog should show something nicer than the identifier, say so:

```elixir
def passkey_display_name(account), do: account.name
```

No fallback is needed. An account that has not filled that in answers `nil`, and this library then
shows the identifier.

### Telling "that name is taken" from "that is not a name"

A registration that the database refuses hands your handler an `Ecto.Changeset`, and the two
reasons want different words. Ask which it was:

```elixir
if Ithibati.Schema.User.identifier_taken?(changeset),
  do: {:error, :username_taken},
  else: {:error, :invalid_username}
```

It looks only at the identifier field. Written by hand this is a scan of the changeset for
`constraint: :unique`, which also finds *your* unique columns — a slug, a handle — and reports a
collision on one of them as the name being taken. The library named that field, so it is the one
that can tell them apart.

It answers `false` for a changeset the database has never seen: a constraint error only exists
once an insert has been refused.

## The first account

An instance starts with nobody, and the first account cannot be invited — there is nobody to write
the invitation. `Ithibati.Identity.Instance.claim/2` is the step that makes a registration page a
one-time page:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:account, User.changeset(%User{}, %{email: email}))
|> Ithibati.Identity.Instance.claim()
|> Ithibati.Identity.Grant.with_key_and_codes(key_attrs)
|> MyApp.Repo.transaction()
```

The claim goes before the grant, for the reason `Instance.claim/2` gives.

The second person to try gets `{:error, :bootstrap, :already_claimed, _}` and leaves no account
behind — the whole transaction rolls back, so the guarantee holds when two people register at the
same moment rather than one after the other. `Instance.needs_setup?/0` is the question your setup
page asks. Why this is a table of this library's rather than a flag on your account row is
[decision 2](docs/design.md#2-the-application-owns-the-users-table); which ways in an application
may offer is
[decision 10](docs/design.md#10-open-registration-and-invitation-only-and-neither-proves-an-address).

## The invitation schema

Optional, and the same arrangement as the account schema: you own the table, this library owns what
has to be right about it. Declare it, add whatever the invitation grants, and configure it:

```elixir
defmodule MyApp.Accounts.Invitation do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.Invitation

  use Invitation, identifier: :email, format: Identifier.email_format()

  schema "invitations" do
    ithibati_invitation()

    field :role, Ecto.Enum, values: [:admin, :author]
    belongs_to :site, MyApp.Sites.Site

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(invitation, attrs, opts \\ []) do
    invitation
    |> invitation_changeset(attrs, opts)
    |> cast(attrs, [:role, :site_id])
    |> validate_required([:role, :site_id])
  end
end
```

`ithibati_invitation/0` adds the invitee's identifier, `token_hash`, `expires_at`, `accepted_at` and
a virtual `:token`. The secret is minted for you and leaves through that virtual field: after the
insert, `invitation.token` is the only copy there will ever be, and the row holds its sha256.
`invitation_changeset/3` takes `days:`, which defaults to seven for a new invitation; pass it to an
existing one to extend it, and the link that was already sent keeps working. The identifier has to
be the field your account schema is identified by, and the configuration refuses the pair when it is
not. An address that already has an account is refused as you write the invitation, which is advice
rather than a guarantee — the unique index on your accounts table is the guarantee.

Accepting composes into your own transaction, so the account and what it is a member of arrive
together or not at all:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:account, User.changeset(%User{}, Invitations.account_attrs(invitation)))
|> Ithibati.Identity.Grant.with_key_and_codes(key_attrs)
|> Ithibati.Identity.Invitations.accept(invitation)
|> Ecto.Multi.insert(:membership, fn %{account: account, invitation: accepted} -> … end)
|> MyApp.Repo.transaction()
```

`accept/2` goes after the step that creates the account, and checks that the account being created
carries the identifier the invitation was addressed to — `{:error, :identifier_mismatch}` otherwise,
so an acceptance form that lets people correct their address cannot hand the invitation to somebody
else. Name the step with `account:` if yours is not called `:account`.

`Invitations.fetch/1` answers the pending, unexpired invitation a token opens, or `nil`.
`expired/0` and `delete_expired/0` are there for a sweeper of your own; this library schedules
nothing. Configure no `invitation_schema` and none of this is reachable —
[decision 9](docs/design.md#9-invitations-are-the-applications-table-and-this-librarys-invariants)
carries the reasoning for all of it.

## The passkeys an account has

`Ithibati.Identity.Passkeys` lists, renames and revokes them:

```elixir
Passkeys.list_keys(account)                       # oldest first, stable order
Passkeys.rename_key(account, id, "My work laptop")
Passkeys.delete_key(account, id)
```

All three are scoped to the account: `list_keys/1` answers only its own, and the two that take an
id answer `{:error, :not_found}` for one belonging to somebody else rather than reaching their row.
A rename cannot move a key to another account.

**The last passkey is not deleted by default** — `{:error, :last_key}`. Recovery codes still reach
the account, so that is not a lockout on its own; it is the step that makes one possible, and
afterwards one sheet of one-time codes is the whole way in. Pass `last: :allow` if your application
has a recovery route of its own. The refusal holds when two passkeys are deleted at the same
moment, which takes more than a count: see
[decision 8](docs/design.md#8-the-second-credential-set-refills-itself).

## The migration

The tables this library owns are created by a migration you write and it fills in:

```elixir
defmodule MyApp.Repo.Migrations.AddIthibati do
  use Ecto.Migration

  def up, do: Ithibati.Migration.up(version: 1)
  def down, do: Ithibati.Migration.down(version: 1)
end
```

Pin the version, as above. An unpinned call would mean a different set of tables depending on when
it runs, and a rollback that undoes neither. It runs after the migrations that create the tables you
own — your accounts table, and your invitations table if you have one — because it points foreign
keys at one and puts an index on the other.

That creates `ithibati_keys`, `ithibati_recovery_codes`, `ithibati_tokens` and `ithibati_bootstrap`,
each with a foreign key to your own account table — the unique index on your invitation table's
`token_hash`, when you configured an invitation schema, and the unique index on your identifier
column,
because account lookup is `Repo.get_by/3`, which raises on a second match rather than signing anybody
in. The column itself is yours to add, on your own table:

```elixir
add :username, :string, null: false
```

If your naming convention is not the one Ecto derives, say what the index should be called and the
library creates it under that name:

```elixir
use User, identifier: :username, constraint_name: :users_username_uniq
```

And if you would rather create it yourself — a partial one, an expression, `citext`, or a composite
with a tenant column — say that instead. The library then checks that a unique index on that column
exists rather than making one, and refuses the migration if it does not:

```elixir
use User, identifier: :username, unique_index: false
```

Configure anything that does not match the defaults:

```elixir
config :ithibati,
  user_schema: MyApp.Accounts.User,   # required — the module that uses Ithibati.Schema.User
  repo: MyApp.Repo,                   # required — the repo this library reads and writes through
  token_validity: %{                  # "session" is 60 days unless you say otherwise
    "device" => {90, :day}
  },
  invitation_schema: MyApp.Accounts.Invitation,  # optional — see below
  users_key_type: :id,                # default :binary_id — compiled into the schemas
  table_prefix: "auth"                # default "ithibati" — compiled into the schemas
```

`token_validity` is merged over the built-in `"session"` entry, so adding a context for a browser
extension does not mean restating the one the session functions promise. A context with no entry
raises rather than inheriting a number nobody chose. The units are `:second`, `:minute`, `:hour`,
`:day` and `:week` — `:month` and `:year` are missing because neither has a fixed length.

The last two settings are read when this library is compiled, so changing them recompiles it; Elixir
refuses to boot against a value it was not built for rather than looking for a table nobody meant.
`users_key_type` is checked against your accounts table as well: before the migration builds
anything, the column its foreign keys point at has to exist, have the type you configured, and carry
a unique index — which is what Postgres requires of any referenced column, so a composite primary
key with a unique index beside it is fine. A disagreement is refused rather than half-applied. The
migration reads the table names and the foreign-key type back out of those schemas, so it cannot
build something they will not go on to read.

A release that adds to the schema reaches you as a second migration of your own, saying where it
starts — `up(from: 1, version: 2)`. You are never asked to write the SQL by hand, and what has
already been applied is recorded where Ecto records it, in your own `schema_migrations`.

## Licence

MIT — see [LICENSE](LICENSE).
