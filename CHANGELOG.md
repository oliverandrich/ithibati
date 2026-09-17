# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases that change the database schema state the new schema version and the required
migration. Add a migration calling `Ithibati.Migration.up(from: <old>, version: <new>)` when
upgrading to one of those releases.

## Unreleased

### Changed

- Require Elixir 1.18 or newer.

### Added

- ExSlop checks run through the existing Credo development and CI gate.
- Separate PostgreSQL, SQLite and MySQL adapter probes characterize storage and transaction
  behavior independently of the PostgreSQL suite.
- SQLite migrations, setup diagnosis and identity operations, including safe credential
  transactions and authentication without joined `RETURNING`. Supports integer account keys
  and UUIDs stored as text or binary; requires enabled foreign keys and the main database.

- MySQL 8.4/InnoDB support with exact UUID/BIGINT foreign-key types, bounded binary indexes,
  migration preflight and partial-installation cleanup, and transactional mutation results.
  Requires READ COMMITTED on every connection; deadlocks and timeouts are not retried.

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

[0.2.0]: https://github.com/oliverandrich/ithibati/releases/tag/v0.2.0
[0.1.3]: https://github.com/oliverandrich/ithibati/releases/tag/v0.1.3
[0.1.2]: https://github.com/oliverandrich/ithibati/releases/tag/v0.1.2
[0.1.1]: https://github.com/oliverandrich/ithibati/releases/tag/v0.1.1
[0.1.0]: https://github.com/oliverandrich/ithibati/releases/tag/v0.1.0
