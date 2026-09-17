# Contributing

Open an issue before implementing a change so we can agree on its scope and fit with the
architecture. Bug reports and questions can be filed directly.

## Running checks

The suite creates and migrates its database but requires a running Postgres server. Set
`PGUSER`, `PGPASSWORD`, `PGHOST` and `PGPORT` as needed; defaults are `postgres`/`postgres`
on `localhost:5432`. For example: `PGUSER=you PGPASSWORD= mise run check`.

Before finishing a change, both checks must pass:

```console
$ mise run check
$ mise run check-without-optional
```

`check` runs the formatter, Credo (including ExSlop), tests, `zizmor` over the workflows, and
`mix docs --warnings-as-errors`. `mix precommit` runs its Elixir checks without mise.

`check-without-optional` tests the core without Phoenix in a clean copy. Removing dependencies
from an existing build is insufficient: leftover Phoenix beams can make `Code.ensure_loaded?`
succeed and hide problems in the optional-dependency guards.

For changes affecting shared browser integration, run both example gates from the repository
root. For a change confined to one example, run that example's gate:

```console
$ (cd examples/open_registration && mix precommit)
$ (cd examples/invitation_only && mix precommit)
```

CI runs both examples in a matrix. Their browser tests are the only tests that execute
`priv/static/ithibati.js`.

To preview documentation, run `mise run docs` and open `http://127.0.0.1:8000`. Python 3 is
required. Stop with Ctrl+C. After editing, run `mix docs --warnings-as-errors` in another
terminal and refresh the page.

## Database adapter probes

The adapter suite contains capability probes and shared SQLite/MySQL identity integration
tests. Run `mise run probe-postgres`, `mise run probe-sqlite` or `mise run probe-mysql`.
Equivalently, run `ITHIBATI_ADAPTER_PROBE=sqlite mix build_and_test` with `postgres`, `sqlite`
or `mysql`. Unknown adapter names fail rather than silently running the PostgreSQL suite.

Each adapter uses `_build/adapter_<name>_<key-type>_<uuid-storage>` and runs `adapter_test/`. Database tests are
serial; the concurrency probes explicitly check out separate connections and synchronize their
work. They cover migration up/down, rollback, UUIDs, large integer values, binary uniqueness,
microsecond timestamps, affected rows, SQL limitations and outer/nested transaction snapshots.
SQLite and MySQL additionally test migrations, metadata, diagnosis, authentication, sessions
and identity races. The SQLite race helper retries only known, rolled-back test operations after busy errors,
with a fixed limit; dedicated tests assert that the library itself exposes these failures.
Run either suite with `ITHIBATI_USERS_KEY_TYPE=id` for integer account keys. SQLite also accepts
`ITHIBATI_SQLITE_UUID_STORAGE=binary` for UUIDs stored as BLOBs (defaults: `binary_id`, `string`).

PostgreSQL uses the `PG*` connection variables above. MySQL uses `MYSQL_HOST`, `MYSQL_PORT`,
`MYSQL_USER` and `MYSQL_PASSWORD`, defaulting to `localhost:3306`, `root` and an empty password.
Use a dedicated local test server/account with database-creation permissions. Both server probes
create `ithibati_adapter_probe` and migrate and clear their own tables there; never use that
database for application data. The MySQL integer variant uses `ithibati_adapter_probe_id`.
The capability repo retains the default REPEATABLE READ isolation, while the separate identity
repo initializes every MySQL connection with READ COMMITTED. MySQL tests cover rejection of
unsupported isolation, deadlocks, lock timeouts and partial DDL recovery without callback retries.

SQLite needs no server: the adapter uses `tmp/adapter_probe_<key-type>_<uuid-storage>.sqlite3`,
WAL and a short busy timeout to exercise writer contention. The suite prints the actual engine version for all
three backends. Do not run two copies of the same adapter probe simultaneously against the same
database. The ordinary `mise run check` still runs the existing PostgreSQL suite; adapter
suites are separate commands.

CI runs the adapter suite for SQLite with text UUIDs, binary UUIDs and integer account keys,
and for MySQL 8.4 with UUID and integer account keys. Each variant has its own build cache;
each MySQL job starts a fresh service container on a dynamically assigned host port. SQLite
uses a local file without a service container. The existing PostgreSQL jobs continue to cover
UUID and integer account keys, the minimum Elixir version and the core without Phoenix.

For a disposable MySQL test server, these commands match the local probe defaults. Keep the
container dedicated to tests; the probes create databases and clear their own tables:

```console
$ docker run --detach --rm --name ithibati-mysql-test --publish 127.0.0.1:3306:3306 --env MYSQL_ALLOW_EMPTY_PASSWORD=yes mysql:8.4
$ docker exec ithibati-mysql-test mysql --protocol=TCP -h127.0.0.1 -uroot -e 'SELECT 1'
$ mise run probe-mysql
$ docker stop ithibati-mysql-test
```

Wait for the SQL readiness command to succeed before running the probe. If port 3306 is already
in use, publish another host port and pass it through `MYSQL_PORT`. SQLite only needs
`mise run probe-sqlite`; the suite creates its file database itself.

### Consumer browser smoke tests

Use a disposable copy of `examples/invitation_only` to qualify another database as a Phoenix
consumer. Keep its Ithibati path dependency and browser asset import pointing at this checkout.
Replace the Postgrex dependency and repo adapter with the selected driver/adapter from
[Configuration](docs/configuration.md#databases), and apply that guide's connection settings in
the copy's `config/test.exs`. Use a dedicated database and retain `Ecto.Adapters.SQL.Sandbox`.

Run `mix deps.get`, `MIX_ENV=test mix assets.setup`, `MIX_ENV=test mix assets.build`, then
`mix test --max-cases 1`. Serial execution also works with SQLite's single writer. These tests
exercise first-account setup, invitation acceptance and refusal of reused links through real
Chrome and the shipped JavaScript. The migrations must run unchanged. A passing adapter suite
alone does not replace this consumer check.

## Architecture

- **`Ithibati.Identity` may not name another context.** It handles accounts, passkeys,
  recovery codes and sessions. Application-specific orchestration belongs in the consumer.
  `Ithibati.Credo.IdentityIsPortable` enforces this boundary.
- **The application owns the `users` table.** Ithibati contributes schema fields,
  associations and validation. It must not assume columns its schema macro does not declare.
- **The web half is optional as one unit.** `phoenix`, `phoenix_live_view` and `plug` are
  optional together. Guard every module under `lib/ithibati/web/` with
  `Code.ensure_loaded?(Phoenix.Component)`. Keep the guard in the module, not in
  `elixirc_paths`; project configuration cannot reliably inspect the build's dependencies.
  Do not introduce separate guards for Phoenix and LiveView.
- **Pass the relying-party id and origin explicitly on every call.** They are not library
  configuration. This also prevents `wax_` from falling back to its configured defaults and
  preserves support for non-browser clients.
- **Verification does not mint a credential.** The caller decides what to issue after a
  successful assertion.
- No `util`/`common`/`helpers`/`shared`/`misc` modules.

## Code and documentation

- Use `with` and pattern matching for error paths instead of nested `if`. Return expected
  failures as `{:ok, _} | {:error, _}`.
- Prefer a clear name, then extraction, before adding a comment. Use `@moduledoc` and `@doc`
  for contracts; reserve `#` comments for reasons the code cannot express. Keep change history
  out of `lib/` and `test/`; it belongs in the tracker and commit messages.
- Documentation references must name a file, not just "the README". The pointer tests check
  `docs/…md` paths. In published docs, link to `page.md#anchor`: ExDoc resolves and rewrites
  `.md` links, while `.html` targets bypass its missing-page checks.
- Use `:utc_datetime_usec` for every timestamp, in schemas and migrations.

## Tests

Write tests before changing behavior. For bug fixes, demonstrate that the regression test
fails on the original bug and passes with the fix. For new behavior, confirm that the test
fails before implementation. For a new test of existing behavior, temporarily break the
behavior it guards and confirm that the intended assertion fails. A failure caused by an
unrelated setup error is not a control check. Use the same technique whenever a test's
coverage is unclear. Prose-only changes do not require new tests.

When temporarily changing code to check a test, restore it and rebuild affected modules:

- For Credo checks, rebuild both `dev` and `test`; rebuilding only one can leave the other
  running a stale version.
- For schema macros, recompile the consuming test fixtures after both the temporary change
  and restoration. They contain the macro expansion from their last compilation.

## Commits

Use Conventional Commits: `type(scope): short description`, with the scope optional.
Add a short body explaining the reason and resulting change, usually one or two sentences.
Omit the body for self-explanatory changes such as a version bump.

## Licence

Ithibati is MIT; contributions use the same licence. Attribute externally sourced code and
state its licence.
