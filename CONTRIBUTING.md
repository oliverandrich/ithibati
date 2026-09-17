# Contributing

Thank you for looking. This library is young and its shape is opinionated, so **open an issue
before writing code**. A patch that contradicts a decision the library is built on is a patch
somebody has to turn down, and finding that out after the work is the expensive way.

Bug reports and questions need no issue first. They are the issue.

## Running it

The suite needs a Postgres server. It creates and migrates its own database but cannot invent a
server. It reads `PGUSER`, `PGPASSWORD`, `PGHOST` and `PGPORT`, falling back to
`postgres`/`postgres` on `localhost:5432`, so a role named anything else has to be passed in —
`PGUSER=you PGPASSWORD= mise run check`. Without a server it stops in the test helper and names
the address it tried.

```console
$ mise run check
```

That is the whole gate: the formatter, Credo, the suite, `zizmor` over the workflows, and
`mix docs --warnings-as-errors`. `mix precommit` is its Elixir half if you would rather not
install [mise](https://mise.jdx.dev).

Two things the gate cannot see from an ordinary checkout, both of which CI runs:

```console
$ mise run check-without-optional   # the core without Phoenix, from a clean copy
$ cd examples/open_registration && mix precommit
```

The examples are documentation that either compiles or does not, and their own suites drive them
in a real browser. They are the only place `priv/static/ithibati.js` is executed.

To preview the documentation locally, run `mise run docs` and open `http://127.0.0.1:8000`.
This builds the docs and serves them with Python 3. Stop with Ctrl+C. After editing, run
`mix docs --warnings-as-errors` in another terminal and refresh the page.

## Architecture — do not violate

- **`Ithibati.Identity` may not name another context.** It is the half that knows who someone is
  and how they prove it: the account row, passkeys, recovery codes, sessions. Enforced by
  `Ithibati.Credo.IdentityIsPortable`. If new code genuinely needs something else, it belongs
  above this, in the consumer.
- **The application owns the `users` table.** The library contributes a schema macro, the fields
  it reads and the changeset pieces that validate them. It never assumes a column the macro did
  not put there.
- **The web half is taken or left as one piece, and LiveView is part of it.** `phoenix`,
  `phoenix_live_view` and `plug` are optional together: every module under `lib/ithibati/web/` is
  guarded by the one sentinel `Code.ensure_loaded?(Phoenix.Component)`, and that guard belongs in
  the module rather than in `elixirc_paths`, which `project/0` reads and which can see nothing
  about the project being built. Do not split it finer. A consumer with Phoenix and without
  LiveView was supported once and cost a nested guard, a second example application, and a class
  of mistake this repository cannot see: a private function used only from the LiveView half is
  dead code in *our* build and a warning in somebody else's.
- **The relying-party id and the origin are per-call parameters**, never library configuration.
  Consolidating them into a config key looks like tidying up and rules out every non-browser
  client. `wax_` itself reads `config :wax_, origin:`/`rp_id:` as defaults, so this rule rests on
  always passing both explicitly.
- **Verification does not mint a credential.** What is issued after a successful assertion is the
  caller's separate decision.
- No `util`/`common`/`helpers`/`shared`/`misc` modules.

## Conventions

- Error paths with `with` and pattern matching, not nested `if`. Expected failures as
  `{:ok, _} | {:error, _}`.
- **Comment in this order: name it → extract it → comment it.** `@moduledoc`/`@doc` are
  wanted; a `#` is the exception and carries a *why*, never a *what*. No change history in
  `lib/` or `test/`: that belongs in the tracker and the commit message.
- **A comment that sends a reader to documentation names the file, never "the README".** A
  filename is checkable and a prose reference is not: `test/documentation_pointers_test.exs`
  fails on a `docs/…md` that does not exist. Write a link inside a published moduledoc as
  `page.md#anchor`, never `page.html#anchor`: ExDoc rewrites the extension itself, and
  `mix docs --warnings-as-errors` skips a `.html` target instead of resolving it.
- Every timestamp is `:utc_datetime_usec`, in the schema and in the migration both.
- Tests first, and **every new test gets a control check**: break the thing it guards, watch
  *that assertion* go red, restore from a copy. A test that does not go red is not evidence. Two
  traps measured here:
  - Sabotaging anything under `credo/` needs **both** environments rebuilt. `MIX_ENV=test mix
    compile --force` leaves the `dev` beam holding the sabotage, and the next `mix credo` reports
    a violation that exists only in that leftover build. Read such a finding as a question about
    the build before believing it.
  - Sabotaging a schema macro needs `mix compile --force` **after the restore**. The fixtures
    under `test/support/` bake the expansion in at their own compile time, so a clean source file
    is not a clean suite — and the dangerous direction is the quiet one, where the sabotage never
    reaches the fixtures and the green suite reads as "this test guards nothing".
- Before "done": `mise run check` is green, and so is `mise run check-without-optional`. Why the
  second cannot be replaced by running the gate with the dependencies removed by hand:
  `Code.ensure_loaded?` answers from the code path, and `_build` still holds the compiled
  Phoenix beams after any ordinary run, so the guard passes and the run then dies on something
  the local build invented. The task works from a clean copy, which is what CI gets.

## Licence

Ithibati is MIT, and a contribution arrives under the same terms. Do not bring code in from
somewhere else without saying where it came from and under what licence.
