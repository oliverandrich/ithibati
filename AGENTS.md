# Ithibati — working rules

Ithibati is an Elixir passkey-authentication library. It is MIT, and no code arrives here
without its licence established first.

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

## The tracker is not in the repository

`.beans/` and `.beans.yml` are gitignored here. The tracker is a personal tool in a format nobody else reads, and this library ships to strangers. So
**do not commit bean files, and do not add them back** — and say so rather than assuming a bean
is safe, because the backlog lives on one machine and `git push` does not back it up.

## Conventions

- Error paths with `with` and pattern matching, not nested `if`. Expected failures as
  `{:ok, _} | {:error, _}`.
- **Comment in this order: name it → extract it → comment it.** `@moduledoc`/`@doc` are wanted; a
  `#` is the exception and carries a *why*, never a *what*. No change history in `lib/`/`test/` —
  that belongs in the tracker and the commit message.
- Write out technical terms; do not invent pictures for them. *Foreign key*, *write path*,
  *constraint*, *boundary* — not doors, shelves or seams.
- **Write like a developer explaining the thing, not like an essayist.** Documentation,
  moduledocs and comments are all covered. Plain declarative sentences: subject, verb, object.
  Name the subject — *Ithibati*, *the migration*, *you* — rather than circling it with *this
  library* every other sentence, and keep one idea per sentence. Six habits, each of which has had to be undone here: inversion for
  emphasis; an em-dash apposition doing the work of a main clause; antithesis and parallel
  construction; the aphoristic closing sentence; nominalisation; withholding the subject for
  effect. The reason is not taste. Prose in this shape reads as generated, a reader discounts it,
  and the content is what pays for the style.
- **Bean IDs (`ithibati-xxxx`) never appear in `lib/`, `test/`, `docs/`, `priv/` or `README.md`**
  — only in the beans and in this file, which live with the tracker. Nothing in this repository
  can resolve one, and a dead ID looks authoritative while sending the next reader nowhere.
  Write the *why* out and leave the reference off. Enforced by `Ithibati.Credo.NoBeanIds`.
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
- **The CI leg without the optional dependencies cannot be reproduced in this checkout — use
  `mise run check-without-optional`, which runs what that leg runs: compile and test, not the
  whole gate.** `Code.ensure_loaded?` answers from the code path, and
  `_build` still holds the compiled Phoenix beams after any ordinary run, so the guard passes and
  the run then dies on something the local build invented. The task works from a clean copy,
  which is what CI gets.
- Before "done": `mise run check` is green. That is the whole gate; `mix precommit` is its Elixir
  half. **It needs a running Postgres** — the suite creates and migrates its own database but
  cannot invent a server. Credentials come from `PGUSER`/`PGPASSWORD`/`PGHOST`/`PGPORT`,
  defaulting to `postgres`/`postgres` on `localhost:5432`, so a local role named anything else
  has to be passed in: `PGUSER=oa PGPASSWORD= mise run check`.

