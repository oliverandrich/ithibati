# Ithibati — working rules

Ithibati is an Elixir passkey-authentication library. **Read `docs/design.md` before changing
anything structural** — it carries the decisions this project is built on, with the reasoning,
and a change that contradicts one of them is a change to that document first.

## The reference implementation

The code is being moved here from **Chapisho**, a self-hostable blog engine, checked out locally at
`/Users/oa/Projekte/privat/chapisho`. It is the source of this library and becomes consumer number
one, which is why this is a move rather than a copy: leaving a second copy behind in Chapisho is how
the two drift.

When something here looks arbitrary, the answer is usually there —
`lib/chapisho/accounts/identity.ex` and its siblings, and the tests under `test/chapisho/`, are
worth reading before inventing an explanation.

Chapisho is AGPL and this library is MIT. Code moving in this direction is fine — it is the same
author relicensing his own work — but **nothing moves the other way**, and no third-party code
arrives here without its licence being established first.

## Architecture — do not violate

Each of these is the enforceable form of a decision; the reasoning is behind the link.

- **`Ithibati.Identity` may not name another context.** It is the half that knows who someone is and
  how they prove it: the account row, passkeys, recovery codes, tokens. This will be enforced by a
  Credo check walking its AST against an allow-list — **the check is not here yet** and bringing it
  across is the first piece of work. If new code genuinely needs something else, it belongs above
  this, in the consumer.
  ([decision 3](docs/design.md#3-ithibatiidentity-may-not-name-another-context))
- **The application owns the `users` table.** The library contributes a schema macro, the fields it
  reads and the changeset pieces that validate them. It never assumes a column the macro did not put
  there. ([decision 2](docs/design.md#2-the-application-owns-the-users-table))
- **The relying-party id and the origin are per-call parameters**, never library configuration.
  Consolidating them into a config key looks like tidying up and rules out every non-browser client.
  Note that `wax_` itself reads `config :wax_, origin:`/`rp_id:` as defaults, so this rule rests on
  always passing both explicitly.
  ([decision 5](docs/design.md#5-non-browser-clients-the-token-is-the-boundary-not-oauth2))
- **Verification does not mint a credential.** What is issued after a successful assertion is the
  caller's separate decision.
- No `util`/`common`/`helpers`/`shared`/`misc` modules.

## The tracker is not in the repository

`.beans/` and `.beans.yml` are gitignored here, unlike in the reference implementation. The tracker
is a personal tool in a format nobody else reads, and this library ships to strangers; it is also
transitional and will be replaced. So: **do not commit bean files, and do not add them back.**

Two things follow. The backlog lives on one machine and is not backed up by `git push` — say so
rather than assuming a bean is safe. And the rule below keeping bean ids out of the source is
stronger here than it looks: nothing in this repository can resolve one.

## Conventions

- Error paths with `with` and pattern matching, not nested `if`. Expected failures as
  `{:ok, _} | {:error, _}`.
- **Comment in this order: name it → extract it → comment it.** `@moduledoc`/`@doc` are wanted; a
  `#` is the exception and carries a *why*, never a *what*. No change history in `lib/`/`test/` —
  that belongs in the tracker and the commit message.
- Write out technical terms; do not invent pictures for them. *Foreign key*, *write path*,
  *constraint*, *boundary* — not doors, shelves or seams.
- **Bean IDs (`ithibati-xxxx`) never appear in `lib/`, `test/`, `docs/`, `priv/` or `README.md`** — only in
  the beans themselves and in this file, which both live with the tracker. The tracker may not
  outlive the repository, and a dead ID looks authoritative and sends the next reader nowhere. This
  matters more here than in an application: these files ship to strangers. Write the *why* out and
  leave the reference off. Chapisho enforces this with a Credo check that should come across too.
- Every timestamp is `:utc_datetime_usec`, in the schema and in the migration both.
- Tests first, and **every new test gets a control check**: break the thing it guards, watch *that
  assertion* go red, restore from a copy. A test that does not go red is not evidence.
- **A control check on anything under `credo/` has to rebuild both environments.** The checks are
  `dev`/`test`-only code, and `MIX_ENV=test mix compile --force` leaves the `dev` beam holding the
  sabotaged version. A later `mix credo` then reports a violation that exists only in the leftover
  build — here it accused `Ithibati.Schema.Identifier`, which the check has allowed since it was
  written. Rebuild both, or read the finding as a question about the build before believing it.
- Before "done": `mise run check` is green. That is the whole gate; `mix precommit` is its Elixir
  half. **It needs a running Postgres**: the suite creates and migrates its own database, but it
  cannot invent a server. Credentials come from `PGUSER`/`PGPASSWORD`/`PGHOST`/`PGPORT`, defaulting
  to `postgres`/`postgres` on `localhost:5432`; a local role named anything else has to be passed in
  (`PGUSER=oa PGPASSWORD= mise run check`). Without a server the run stops in the test helper, naming
  the address it tried, before any test runs.

## Scope

Nothing is released. Until the extraction is complete there are no consumers but Chapisho and
therefore **nothing to migrate and no backwards compatibility to keep** — if the data or the API
contradicts the intended design, the design wins. This paragraph expires with the first Hex
release; whoever reads it after that must delete it.
