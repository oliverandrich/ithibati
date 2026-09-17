# Configuration and schemas

[Getting started](getting_started.md) uses a username, integer account IDs and Ithibati's default
table names. This page covers the options for adapting that setup to an existing application.

## Configuration

Set these keys under `config :ithibati`:

| Key | Default | Purpose |
| --- | --- | --- |
| `repo` | Required | The Ecto repo Ithibati reads and writes through |
| `user_schema` | Required | The account schema using `Ithibati.Schema.User` |
| `users_key_type` | `:binary_id` | Type used for foreign keys to the account table |
| `table_prefix` | `"ithibati"` | Prefix of Ithibati's table names |
| `session_validity` | `{60, :day}` | Maximum age of a session |
| `invitation_schema` | Unset | Application-owned invitation schema, when invitations are enabled |

For example, in `config/config.exs`:

```elixir
config :ithibati,
  repo: MyApp.Repo,
  user_schema: MyApp.Accounts.User,
  users_key_type: :id,
  session_validity: {30, :day}
```

Keep the generated `import_config` line last. `users_key_type` and `table_prefix` are compiled
into the schemas; they cannot be supplied only in `config/runtime.exs`. Changing either
requires recompilation and a database layout that matches the new value.

Session validity accepts a positive integer and one of `:second`, `:minute`, `:hour`, `:day`
or `:week`. It measures age from session creation, rather than extending the session on each
request. Invalid values raise when a session is issued or looked up.

The relying-party ID and origin are passed to ceremonies, not configured here. See
[The relying party](ceremonies.md#the-relying-party).

## Identifiers

Declare the identifier on your own account schema:

```elixir
alias Ithibati.Schema.Identifier
alias Ithibati.Schema.User

use User, identifier: :email, format: Identifier.email_format()
```

Use `ithibati_account()` inside the schema and call `identifier_changeset/2` in your changeset.
The macro declares the identifier field and the `passkeys`, `recovery_codes` and `sessions`
associations. Your application declares any additional fields.

`identifier_changeset/2` trims and lowercases the identifier, requires a value and applies
`format:` when supplied. Omitting `format:` keeps normalization and presence validation.
Choosing an email identifier does not verify that someone owns the mailbox; Ithibati sends no mail.

### Formats and messages

| Helper | Accepts |
| --- | --- |
| `Identifier.username_format/0` | 1–30 lowercase ASCII letters, digits or underscores |
| `Identifier.email_format/0` | A practical email-address shape, including `you@localhost`; quoted local parts such as `"a b"@example.com` are refused |

Changesets lowercase identifiers before applying the username pattern. Direct callers of
`username_format/0` receive a regex only; normalize mixed-case input before matching it.

Supply a regex for your own rules:

```elixir
@handle ~r/\A[a-z][a-z0-9_]{2,29}\z/

use User, identifier: :handle, format: @handle,
  format_message: "must start with a letter and contain 3–30 letters, digits or underscores"
```

Define module attributes before `use`. An explicitly supplied `format: nil` raises.
`format_message:` requires `format:`. The identifier itself must be a literal atom.

To distinguish an identifier collision from other validation failures after an insert, use
`Ithibati.Schema.User.identifier_taken?/1` on the returned changeset.

### Display names

A display field can preserve the spelling you want people to see while the identifier remains
normalized. To show it in a passkey dialog, define this function on your account schema:

```elixir
def passkey_display_name(account), do: account.name
```

When it returns `nil`, Ithibati uses the identifier. Your schema and migration must both declare
any display field you add.

### Case and indexes

For writes through the changeset, lowercasing plus a normal unique index prevents names such as
`AdaLovelace` and `adalovelace` from creating separate accounts. Writes that bypass the changeset
need their own normalization.

An existing application may use PostgreSQL `citext` to compare values without regard to case.
That is a database choice; Ithibati's changeset still lowercases what it writes. Keep the Ecto
field type as `:string` and maintain the unique index described below. To create an invitation
identifier with the same database type, pass `type: :citext` to
`Ithibati.Migration.invitation_columns/1` after installing the extension. See the
[invitation migration](invitations.md#2-configure-and-migrate).

## Primary keys and table names

Set `users_key_type: :id` for integer account IDs or `:binary_id` for UUIDs. Ithibati's default
is `:binary_id`; the default account migration in the walkthrough uses `:id` explicitly.
The migration verifies the actual referenced column's type and uniqueness before creating
foreign keys.

`table_prefix: "auth"` changes names such as `ithibati_sessions` to `auth_sessions`. It is a
prefix of the table name, not a PostgreSQL schema prefix. Keep the compiled setting and the
migrated database in agreement.

## Migrations

Your application creates the account table and identifier column. Ithibati creates its own
tables and, by default, the identifier's unique index:

```elixir
defmodule MyApp.Repo.Migrations.AddIthibati do
  use Ecto.Migration

  def up, do: Ithibati.Migration.up(version: 1)
  def down, do: Ithibati.Migration.down(version: 1)
end
```

Run this after the account-table migration. Use `:utc_datetime_usec` for timestamps in schemas
and migrations. When adding a required identifier to an existing populated table, plan its
backfill before applying `null: false`.

The migration validates the account column, referenced key and required indexes before building
its tables. It leaves the account table and identifier column under your ownership, including
on rollback.

Deleting an account cascades to its passkeys, recovery codes and sessions. The bootstrap row
remains with a null account reference: deleting the first account does not reopen initial setup.

### Naming or maintaining an index

To choose the identifier index name, set it on the schema:

```elixir
use User, identifier: :username, constraint_name: :users_username_uniq
```

To maintain it in your own migration:

```elixir
use User, identifier: :username, unique_index: false
```

The migration still checks for a unique index on that column. It must guarantee uniqueness of
the identifier alone across the whole table. A partial index, expression index or index on
`[:tenant_id, :username]` does not satisfy that requirement. Setting `unique_index: false`
changes who creates the index, not the uniqueness Ithibati requires.

### Upgrading the database schema

Keep existing migrations pinned to their original version. `Ithibati.Migration.current_version/0`
returns the version supported by the installed library. This checkout uses version 1.

If a future release introduces version 2, its changelog should name the upgrade. Add a new
migration at that point; do not edit the migration already applied:

```elixir
def up, do: Ithibati.Migration.up(from: 1, version: 2)
def down, do: Ithibati.Migration.down(from: 1, version: 2)
```

This is the upgrade pattern, not a migration to run against the current schema version.

## Invitations

Set `invitation_schema` only when your application provides an invitation schema and table.
The identifier field must match the account schema's identifier. The
[invitation guide](invitations.md) covers the columns, token index and acceptance transaction.

After changing the integration, run [`mix ithibati.doctor`](doctor.md) against the target database.
