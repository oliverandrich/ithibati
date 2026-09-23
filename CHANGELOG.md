# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases that change the database schema state the new schema version and the required
migration. Add a migration calling `Ithibati.Migration.up(from: <old>, version: <new>)` when
upgrading to one of those releases.

## [Unreleased]

### Upgrading from 0.5.0

Database schema version is now 4. An application that uses invitations and created its table
before this release adds the inviter column with a new migration:

```elixir
def change do
  alter table(:invitations) do
    Ithibati.Migration.invitation_inviter_column(version: 4)
  end
end
```

Ithibati's own tables do not change in version 4, so `up(from: 3, version: 4)` succeeds and
builds nothing. Write it if your deployment steps through versions; it is not required.

Keep older migrations pinned. `invitation_columns/1` produces the column only from `version: 4`,
so a migration file already written goes on producing the table it produced then and a rebuilt
database does not receive it twice. An application that does not use invitations has nothing to
do. See [Upgrading the database schema](docs/configuration.md#upgrading-the-database-schema).

### Added

- `invited_by_id` on the invitation schema, set by the caller with `put_change/3` rather than
  cast — who is inviting is known to the caller and to nobody else, least of all to a form — and
  `Ithibati.Migration.invitation_inviter_column/1` for a table that predates it. The column and
  not the association: declaring `belongs_to` in the macro would pin `user_schema` to compile
  time and would stop compiling for an application that had already written it by hand. See
  [Invitations](docs/invitations.md#showing-and-withdrawing-pending-invitations).
- `Ithibati.Identity.Invitations.pending_query/0`, `pending/0` and `withdraw/1`. The module could
  open an invitation and accept it, but an application could not see what was outstanding or take
  one back, so every consumer wrote the same three queries against a schema this library
  declares. `pending_query/0` hands over the predicate `fetch/1` uses, for the application to
  scope, order and preload; `withdraw/1` rechecks the acceptance inside its delete, so a
  withdrawal cannot remove an invitation that is being redeemed at that moment.

### Changed

- `Ithibati.Identity.Instance.issue_code/0` and `authorize_code/1` answer
  `{:error, :claim_is_open}` when `initial_claim` is not `:operator_code`. They raised an
  `ArgumentError` before, which a caller could not tell apart from a misconfigured repository
  raising the same kind of error from the same call. A mode that is neither `:open` nor
  `:operator_code` still raises: that is a mistake in the configuration, not a state.

  An application that guarded these calls to avoid the raise can drop its guard. One that
  rescued `ArgumentError` around them must stop, or it will swallow the configuration error it
  was never meant to catch.

## [0.5.0] - 2026-09-20

### Upgrading from 0.4.0

Database schema version is now 3. Existing installations must add a new application migration
before deploying a release with this change:

```elixir
def up, do: Ithibati.Migration.up(from: 2, version: 3)
def down, do: Ithibati.Migration.down(from: 2, version: 3)
```

Keep older migrations pinned. Version 3 adds the operator-code digest table; it preserves
existing accounts, passkeys and sessions. Apply the migration even if the application keeps the
default `initial_claim: :open`. See [Upgrading the database schema](docs/configuration.md#upgrading-the-database-schema).

### Added

- Optional `initial_claim: :operator_code` protects the first-account claim with an
  operator-issued code. `Ithibati.Identity.Instance` issues and rotates the code, exchanges it
  for a ten-minute authorization, and consumes that authorization in the account transaction.
  The default `:open` mode preserves existing claim behavior. See
  [Invitations and the first account](docs/invitations.md#protect-the-first-account-claim).
- The invitation-only example demonstrates the operator command, code form and protected
  registration handler. `mix ithibati.doctor` checks the new table and configuration.

## [0.4.0] - 2026-09-18

### Upgrading from 0.3.0

No database migration is required; Ithibati's database schema remains at version 2.
Invitation mail is opt-in. Existing registration handlers continue to work without mail
configuration.

### Added

- A third Phoenix example, `examples/email_registration`, demonstrates one email address as
  account identifier and mail recipient, a development mailbox preview, and passkey registration
  through emailed invitation links, including for the first account.

- Optional delivery of existing invitation links with `Ithibati.InvitationMail`, using
  application-owned content and mailer callbacks. Supports text and optional HTML, explicit
  delivery errors and a guard against sending inside a transaction. The invitation example
  demonstrates opt-in public registration by email through its existing acceptance flow.

## [0.3.0] - 2026-09-18

### Breaking changes

- Database schema version is now 2. Existing installations must add a migration calling
  `Ithibati.Migration.up(from: 1, version: 2)` before serving requests with this release.
  The new challenge table preserves existing accounts and credentials. Keep older migrations
  pinned; rollback uses `Ithibati.Migration.down(from: 1, version: 2)` with the older application.
  See [Upgrading the database schema](docs/configuration.md#upgrading-the-database-schema).
- Challenge consumption now rejects outer application transactions, which could restore a
  consumed challenge on rollback. Transactions inside handler callbacks remain supported.
  See [Challenge storage](docs/ceremonies.md#challenge-storage).
- Require Elixir 1.18 or newer because the ExSlop development checks require it. The project
  deliberately keeps one supported floor for consumers and development tooling.
- Removed `table_oid/3` from `Ithibati.Catalogue`; use `Ithibati.Catalogue.table/3` instead.

### Changed

- Prepare identity transactions before lock queries and avoid redundant MySQL isolation checks
  within prepared operations; connection isolation is still checked at each identity entry point.
- Route all catalogue metadata through the repo's adapter and report unsupported adapters clearly.
- Database catalogue queries and storage types live in separate PostgreSQL, SQLite and MySQL
  modules.

### Fixed

- Treat empty adapter probe key-type and UUID-storage environment variables as defaults,
  including their build directories, so inherited blank CI matrix values do not abort probes.
- Compile project checks before every `mix credo` invocation, including the precommit gate,
  so restored CI build caches cannot run outdated architecture rules against current source.
- WebAuthn challenges are consumed atomically in the database before verification, including
  failed attempts. Replaying the original session cookie no longer allows a signed assertion
  or registration response to be accepted again. Outstanding pre-upgrade challenges are refused;
  clients must start a new ceremony.

### Added

- Account-wide session revocation with `Sessions.revoke_all/1` and browser logout with
  `Gate.log_out_all/1`, including disconnect broadcasts for revoked sessions. See
  [Sign out everywhere](docs/ceremonies.md#sign-out-everywhere).
- `Sessions.delete_expired/0` for application-scheduled session maintenance. See
  [Session cleanup](docs/ceremonies.md#session-cleanup).
- ExSlop checks run through the existing Credo development and CI gate.
- Separate PostgreSQL, SQLite and MySQL adapter probes characterize storage and transaction
  behavior independently of the PostgreSQL suite.
- SQLite migrations, setup diagnosis and identity operations, including safe credential
  transactions and authentication without joined `RETURNING`. Supports integer account keys
  and UUIDs stored as text or binary; requires enabled foreign keys and the main database.
- MySQL 8.4/InnoDB support with exact UUID/BIGINT foreign-key types, bounded binary indexes,
  migration preflight and partial-installation cleanup, and transactional mutation results.
  Requires READ COMMITTED on every connection; deadlocks and timeouts are not retried.
- CI coverage for PostgreSQL capability probes, SQLite text/binary UUIDs and integer keys,
  and MySQL 8.4 UUID/integer keys.
- Concise setup for all three databases in [Configuration](docs/configuration.md#databases),
  with storage, transaction and migration recovery details in [Database behavior](docs/databases.md).

## [0.2.0] - 2026-09-17

### Upgrading from 0.1.3

No database migration is required; Ithibati's database schema remains at version 1.
Public schema options, changeset functions and handler callbacks remain compatible.
Rebuild browser assets to include the new `exception` detail in `ithibati:failed` events.
Existing handlers for these events can continue reading the `error` field.

The undocumented `__changeset__` helpers in `Ithibati.Schema.User` and
`Ithibati.Schema.Invitation` now take an options map at arities 3 and 4, previously 6 and 7.
Applications should use their schema's generated changeset functions instead of calling these
internal helpers directly.

### Added

- `Ithibati.Migration.invitation_columns/1` accepts `type:` for the identifier column, such as
  `:citext`. The default remains `:string`; applications provide any required database extension.
- `mix ithibati.doctor` checks that each route mount names an available handler with all required
  callbacks. This catches missing handlers before the first sign-in request.
- `Ithibati.Ceremony.codes/0` lists the library's ceremony failure codes, so applications can test
  that their error messages cover each one.
- `ithibati:failed` includes an `exception` field with the browser's `DOMException` name, or `nil`.
  This preserves diagnostic details, such as `SecurityError`, alongside the error code.
- A [configuration and schema reference](docs/configuration.md) covering identifiers, indexes,
  primary keys and migrations.
- `mise run docs` builds the documentation and serves a local preview at `http://127.0.0.1:8000`.
  The preview server requires Python 3.

### Changed

- Schema macros carry their options as one map, so adding an option no longer changes the
  internal changeset arities. Public schema APIs and validation behavior are unchanged.
- Reorganized the README and guides around setup and common integration tasks, with configuration
  variants in a separate reference page.
- Reworked module and function documentation to state inputs, results and failure behavior.
  Shortened internal comments while preserving transaction and concurrency guarantees.

### Fixed

- Corrected the contributor instructions for both browser examples and the username-format
  reference. Restored concise explanations of origin trust, RP IDs, recovery-code delivery,
  integer foreign keys and current test-coverage limits.
- `mix ithibati.doctor` reports unsupported database adapters before issuing SQL and skips
  dependent database checks, instead of failing with a connection or catalogue-query error.
- Corrected documentation for `needs_setup?/0`, default passkey labels and identifier-index
  metadata, and replaced the enum migration example with its database storage type.
- Documented the existing `recovery_failed` error code and clarified that a failed browser
  exchange does not establish whether the server spent the code.
- Completed the invitation walkthrough, including handling invitations that expire or are
  accepted between the challenge and registration requests.
- Corrected the identifier-index guidance: an application-managed index must guarantee uniqueness
  of the identifier alone across the whole table. Partial and composite indexes do not qualify.

## [0.1.3] - 2026-09-16

### Fixed

- Naming a handler in a route mount no longer creates a compile-time dependency on that module.
  Changes to the handler or its dependencies no longer trigger unnecessary router recompilation.

## [0.1.2] - 2026-09-16

### Added

- `format_message:` on `Ithibati.Schema.User` and `Ithibati.Schema.Invitation` lets applications
  customize the validation message for an identifier that does not match its format.

### Fixed

- Registration now reports `already_enrolled` when the browser refuses a credential it already
  holds. Previously, this was reported as `ceremony_failed`. Browser and server refusals now use
  the same code for an already-enrolled credential.

### Documentation

- Documented the need for consistent lock ordering when a transaction writes to both Ithibati's
  bootstrap row and an application-owned singleton row. See
  [Invitations and the first account](docs/invitations.md#composing-additional-application-steps).

## [0.1.1] - 2026-09-16

Documentation-only release; library behaviour is unchanged.

### Changed

- Revised the README, guides, module documentation and comments for clarity.
- Added an OpenGraph image to the documentation site for link previews.

### Fixed

- Corrected four inaccurate comments about repo validation, the doctor's callback list and
  internal counts.

## [0.1.0] - 2026-09-15

Initial release: passkey authentication for Elixir applications, with authorization left to
the application.

### Added

- Passkey registration and authentication through WebAuthn and [`wax_`](https://hex.pm/packages/wax_),
  including first-account setup and additional passkeys on existing accounts.
- Single-use recovery codes with automatic refill when the last unused code is spent.
- Revocable server-side sessions. The browser holds the secret and the database stores its
  SHA-256 digest. Session validity defaults to sixty days and is configurable through
  `config :ithibati, session_validity:`.
- Optional invitations with token generation, expiry and redemption. The application owns the
  invitation table and decides what accepting one grants.
- Schema macros for application-owned account and invitation tables.
- Versioned migrations through `Ithibati.Migration`, called from the application's own migrations.
  Invitation column and index helpers support adding invitations after initial setup. Migrations
  check required columns and types and report missing identifier or token-hash columns before
  attempting to index them.
- An optional Phoenix integration with ceremony routes, a session gate and a LiveView browser
  hook. Phoenix, LiveView and Plug are optional dependencies used together.
- `mix ithibati.doctor` with twelve setup checks, including invitation-token uniqueness and
  required handler callbacks.
- `POST /recovery` for signing in with a recovery code. The handler's `recovered/3` callback
  receives the account and any replacement code batch to display.
- Three optional Credo checks for consuming applications.

[0.5.0]: https://github.com/oliverandrich/ithibati/releases/tag/v0.5.0
[0.4.0]: https://github.com/oliverandrich/ithibati/releases/tag/v0.4.0
[0.3.0]: https://github.com/oliverandrich/ithibati/releases/tag/v0.3.0
[0.2.0]: https://github.com/oliverandrich/ithibati/releases/tag/v0.2.0
[0.1.3]: https://github.com/oliverandrich/ithibati/releases/tag/v0.1.3
[0.1.2]: https://github.com/oliverandrich/ithibati/releases/tag/v0.1.2
[0.1.1]: https://github.com/oliverandrich/ithibati/releases/tag/v0.1.1
[0.1.0]: https://github.com/oliverandrich/ithibati/releases/tag/v0.1.0
