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

Your application keeps its own `users` table, its own roles and its own invitations, and composes
the grant into one transaction with the library's half.

## Design

Six decisions shape it, and [`docs/design.md`](docs/design.md) carries each one with its reasoning:

1. [The name](docs/design.md#1-the-name)
2. [The application owns the `users` table](docs/design.md#2-the-application-owns-the-users-table)
3. [`Ithibati.Identity` may not name another context](docs/design.md#3-ithibatiidentity-may-not-name-another-context)
4. [A grant is `Ecto.Multi` composition, not an event](docs/design.md#4-a-grant-is-ectomulti-composition-not-an-event)
5. [Non-browser clients ride on the token, not on OAuth2](docs/design.md#5-non-browser-clients-the-token-is-the-boundary-not-oauth2)
6. [No authenticator name data ships with it](docs/design.md#6-no-authenticator-name-data-ships-with-this-library)

## The account schema

Your application keeps its own account schema and its own table. This library adds one field — the
one you name — three associations and three functions, and nothing else:

```elixir
defmodule MyApp.Accounts.User do
  use Ecto.Schema

  alias Ithibati.Schema.User

  use User, identifier: :email, format: User.email_format()

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

`format:` is optional, and `email_format/0` offers a pattern for addresses rather than imposing one.
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
it runs, and a rollback that undoes neither.

That creates `ithibati_keys`, `ithibati_recovery_codes`, `ithibati_tokens` and `ithibati_bootstrap`,
each with a foreign key to your own account table — and the unique index on your identifier column,
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
  users_key_type: :id,                # default :binary_id — compiled into the schemas
  table_prefix: "auth"                # default "ithibati" — compiled into the schemas
```

The last two are read when this library is compiled, so changing them recompiles it; Elixir refuses
to boot against a value it was not built for rather than looking for a table nobody meant. The
migration reads the table names and the foreign-key type back out of those schemas, so it cannot
build something they will not go on to read.

A release that adds to the schema reaches you as a second migration of your own, saying where it
starts — `up(from: 1, version: 2)`. You are never asked to write the SQL by hand, and what has
already been applied is recorded where Ecto records it, in your own `schema_migrations`.

## Licence

MIT — see [LICENSE](LICENSE).
