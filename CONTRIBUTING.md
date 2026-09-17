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

`check` runs the formatter, Credo, tests, `zizmor` over the workflows, and
`mix docs --warnings-as-errors`. `mix precommit` runs its Elixir checks without mise.

`check-without-optional` tests the core without Phoenix in a clean copy. Removing dependencies
from an existing build is insufficient: leftover Phoenix beams can make `Code.ensure_loaded?`
succeed and hide problems in the optional-dependency guards.

For changes affecting the example or browser integration, also run:

```console
$ cd examples/open_registration && mix precommit
```

CI runs this too. The example's browser tests are the only tests that execute
`priv/static/ithibati.js`.

To preview documentation, run `mise run docs` and open `http://127.0.0.1:8000`. Python 3 is
required. Stop with Ctrl+C. After editing, run `mix docs --warnings-as-errors` in another
terminal and refresh the page.

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
fails before implementation. Deliberately break the implementation as an additional control
when it is unclear whether a test exercises the intended behavior. Prose-only changes do not
require new tests.

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
