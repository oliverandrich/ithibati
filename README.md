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

## What it runs on

**Elixir 1.17 or newer**, and **Postgres**. Postgres is not a default but a requirement: the
migration reads the account table's own catalogue entries to check what it is about to point a
foreign key at, and no other adapter answers those questions. CI builds both ends of the Elixir
range and both account-key types.

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

### The identifier is yours to choose

There is no default. Pass the field an account is known by, and a pattern if you want one:

```elixir
use User, identifier: :username, format: ~r/^[a-z0-9][a-z0-9_-]{2,31}$/
use User, identifier: :handle
```

`format:` is optional, and `Ithibati.Schema.Identifier.email_format/0` offers a pattern for
addresses rather than imposing one.
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
