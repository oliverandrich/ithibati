# Database behavior

Start with the connection examples in [Configuration and schemas](configuration.md#databases).
This guide explains storage requirements, transaction composition and migration failures.
Ithibati supports PostgreSQL, SQLite and MySQL; SQL Server and MariaDB are outside that scope.

## Verified versions

The adapter suites have been run against these versions. They record the actual engine version,
including SQLite's native library supplied by Exqlite.

| Database | Engine | Adapter or driver |
| --- | --- | --- |
| PostgreSQL | 18.6 | Postgrex 0.22.4 |
| SQLite | 3.53.4 | ecto_sqlite3 0.24.1, Exqlite 0.40.0 |
| MySQL | 8.4.11, InnoDB | MyXQL 0.9.0 |

These are the verified combinations, not a claim that every server and driver version has been
tested. Consuming applications select their own dependencies.

## PostgreSQL

### Storage and schemas

Account keys may use `uuid`, `smallint`, `integer` or `bigint`, including domains over those
types. Configure `users_key_type: :binary_id` for UUIDs or `:id` for integer keys. The referenced
column must be unique on its own. A full unique index or primary key qualifies; a composite,
partial or expression index does not. Additional `INCLUDE` columns are allowed.

Binary values use `bytea`; timestamps use `:utc_datetime_usec` in Ecto and microsecond-capable
`timestamp without time zone` columns. The account identifier's type remains application-owned.
For case-insensitive identifiers using `citext`, see
[Case and indexes](configuration.md#case-and-indexes).

Catalogue lookup uses the connection's search path when no schema prefix is supplied. Migrations
use their explicit prefix or the repo's `migration_default_prefix`; Doctor uses the latter.
Keep those settings and runtime queries aligned. Ithibati's `table_prefix` changes table names,
such as `ithibati_keys` to `auth_keys`; it does not select a PostgreSQL schema.

### Transactions

Use READ COMMITTED isolation, including for outer application transactions. Credential operations
lock the account with `FOR NO KEY UPDATE` before making decisions across several rows. Separate
statements after acquiring that lock see preceding commits, protecting recovery-code replacement
and deletion of the last passkey. The lock lasts until the outermost transaction ends.

## SQLite

### Storage and schemas

SQLite supports the unprefixed main database. Integer account keys and UUIDs are supported.
UUID storage follows the adapter-wide `config :ecto_sqlite3, :binary_id_type` setting:
`:string` by default, or `:binary` for BLOB storage. Configure it before creating tables and keep
it consistent across the application. Foreign keys must be enabled on every connection so
account deletion cascades to credentials while preserving the bootstrap claim.

Ithibati's `table_prefix` still changes table names normally. Schema prefixes and
`migration_default_prefix` are unsupported.

### Transactions

SQLite allows one writer at a time. Ithibati starts its own credential transactions in immediate
mode and reserves the writer before deciding about recovery codes or the last passkey. Locks
last until the outermost transaction ends.

For application-owned transactions and `Ecto.Multi`, use `default_transaction_mode: :immediate`
as shown in the configuration guide, or pass `mode: :immediate` to `Repo.transaction/2`.
This reserves the writer before application reads. A nested transaction cannot upgrade an
already stale outer snapshot.

An existing deferred transaction can proceed if its snapshot is still current. If another
writer has committed since its earlier read, SQLite raises before deciding from stale data.
Lock contention can also exceed `busy_timeout` and raise an adapter error.

## MySQL

### Storage and schemas

Use InnoDB for account and invitation tables and keep `foreign_key_checks = 1`. Only the repo's
selected database is supported, without schema prefixes. Doctor diagnoses these requirements.

Account IDs may be UUIDs in `BINARY(16)` or signed/unsigned `BIGINT`s. Ithibati matches the foreign
key's signedness to the existing account column; smaller integer widths are refused. The default
MyXQL auto-increment key uses unsigned BIGINT.

Indexed credential IDs use `VARBINARY(1023)` and digests use `VARBINARY(32)`, with full-column unique
indexes. A prefix-only index does not qualify. Invitation timestamps must be `DATETIME(6)` and
their token digest `VARBINARY(32)`; `Ithibati.Migration.invitation_columns/1` chooses these types.

Identifier normalization remains the changeset's responsibility. The application's column
collation determines which normalized strings compare equal, including accent sensitivity.
Use the same identifier semantics for invitations and accounts.

### Transactions

Set READ COMMITTED on every connection before starting transactions. Ithibati checks session
isolation before its credential transactions; do not override it for individual transactions
that call Ithibati. MySQL's default REPEATABLE READ can retain an earlier application snapshot
even after a nested transaction starts and is unsupported for these operations.

MySQL has no mutation `RETURNING`. Ithibati locks the matching row, checks the conditional write
and reads the result in one transaction. Account locks serialize recovery-code replacement and
final-passkey deletion, including inside existing application transactions. Deadlocks and lock
timeouts propagate as database errors.

### Recovering a failed migration

MySQL commits DDL statements individually. Migrations validate application-table requirements
and resolve application-index conflicts before creating owned tables, but an unexpected DDL
failure can still leave a partial schema. Inspect it before retrying.

For an initial installation with no authentication data to retain, a temporary recovery migration
may call `Ithibati.Migration.down(version: 2)` in its `up/0`, then retry the original installation.
This removes any existing Ithibati tables and its managed application indexes. It is destructive
and must not be used as an automatic repair of a populated installation. Your account and
invitation tables remain application-owned.

## Handling database failures

Lock timeouts, deadlocks and stale snapshots are infrastructure failures, separate from expected
results such as `:invalid` or `:last_key`. Ithibati never automatically replays an application
callback. If your application retries, restart the entire transaction, bound the attempts and
ensure that external side effects are safe to repeat.

All three backends use Ithibati schema version 2. Keep applied migrations pinned to their original
version; see [Upgrading the database schema](configuration.md#upgrading-the-database-schema).
