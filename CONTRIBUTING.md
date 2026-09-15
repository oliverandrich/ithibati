# Contributing

Thank you for looking. This library is young and its shape is opinionated, so **open an issue
before writing code**. A patch that contradicts a decision the library is built on is a patch
somebody has to turn down, and finding that out after the work is the expensive way.

Bug reports and questions need no issue first. They are the issue.

## Running it

The suite needs a Postgres server. It creates and migrates its own database but cannot invent a
server, and it reads `PGUSER`, `PGPASSWORD`, `PGHOST` and `PGPORT`, falling back to
`postgres`/`postgres` on `localhost:5432`. Without one it stops in the test helper and names the
address it tried.

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

## Conventions

They are in [AGENTS.md](AGENTS.md), written for whoever or whatever is editing the code. Two are
worth knowing before you start, because they change how a change is shaped rather than how it
looks: tests come first and every new test gets a control check, and the architecture rules under
"do not violate" are the enforceable form of decisions rather than preferences.

## Licence

Ithibati is MIT, and a contribution arrives under the same terms. Do not bring code in from
somewhere else without saying where it came from and under what licence.
