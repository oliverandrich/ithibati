# Ithibati, open registration

Anyone who picks a free username gets an account. That is the whole of this instance's policy, and
it lives in one function — `registration_subject/2` in `lib/ithibati_open/auth.ex`, which returns
`{:ok, username}` and nothing else.

Read it beside [`examples/invitation_only`](../invitation_only), where the same function is the
place people are turned away. That is the point of having both: the hinge is one callback, and
everything around it is the same.

It is a `mix phx.new` application with nothing taken out — daisyUI, the heroicons plugin,
`core_components.ex` and all — so that what you compare against is the Phoenix you would have
written anyway, and the only unfamiliar thing in it is Ithibati.

## Running it

Needs Postgres. Credentials are the generated defaults in `config/dev.exs`.

```
mix setup
mix phx.server
```

Then open <http://localhost:4000> and register. (The invitation example uses the same port, so
run one at a time, or give this one `PORT=4001`.) No hardware needed if you would rather not: Chrome
DevTools has a virtual authenticator under *More tools → WebAuthn*. Register as often as you like —
that is what open means. `mix ecto.reset` starts over.

## The browser tests

`test/features/` drives these pages in a real Chrome, through the JavaScript the library ships —
`mix test` runs them like anything else.

They need a chromedriver matching *your* Chrome, because a driver refuses a browser from another
major version. That version is therefore not pinned in the tracked `mise.toml`; run `mix test`
once and it will print the exact line, something like:

```
mise use --path ../../mise.local.toml chromedriver@150
```

CI uses the runner's own driver instead. There is no way to skip these tests quietly — a missing
driver fails the run and says what to do.

## What to read, in this order

| | |
|---|---|
| `lib/ithibati_open/auth.ex` | The three decisions Ithibati refuses to make for you. Here they are as short as they go. |
| `lib/ithibati_open/accounts/user.ex` | Your account table stays yours, and the identifier here is a **username** — `Identifier.username_format/0`, one of the two patterns the library offers rather than imposes. Neither is a default: what an identifier may look like is not its business. |
| `config/config.exs` | What Ithibati is told: your repo, your account schema, the type your `users.id` has. |
| `priv/repo/migrations/` | Application tables first, then pinned Ithibati versions 1, 2 and 3 in separate migrations. |
| `lib/ithibati_open_web/router.ex` | One macro call for the ceremony, its own pipeline, and `Ithibati.Web.Gate` for who is signed in. |
| `lib/ithibati_open_web/live/sign_in_live.ex` | The LiveView says *when*; the hook does the round-trips. |
| `assets/js/app.js` | One import line, merged into the hooks the socket already takes. |

## Why the LiveView does not do the ceremony itself

A ceremony ends in a session cookie and a LiveView cannot set one. So the hook posts to the
endpoints over `fetch` and follows the redirect the handler answers with; the LiveView keeps what it
is good at, which is having the fields and validating them before any of it starts.

The ceremony routes have a pipeline of their own rather than sharing `:browser`, and this example
is how that came to be written down: `:browser` accepts `["html"]`, so it refused the hook's request
with a **406** before the controller was ever reached. The library's README said to use `:browser`
until this example proved otherwise. What the pipeline does need is the session the challenge waits
in and `protect_from_forgery` — post to `/auth/registration/challenge` without the token and you get
a 403, as `test/ithibati_open_web/ceremony_test.exs` insists.

## Two lines a real application does not need

`config/config.exs` adds `--alias:ithibati=…` to esbuild, and `assets/package.json` exists at all.
Both are artefacts of living inside the library: a path dependency has no `deps/ithibati` for the
bare specifier to resolve against, and Node's module resolution would otherwise walk up into the
library's own `package.json`. Take Ithibati from Hex and neither is needed.

## What this example is not

The recovery codes are shown on a page of their own and then gone — that part is real. But a real
application would think harder about what happens next: they are the only copy, and the digests in
the database cannot bring them back.
