# Ithibati with LiveView

The documented path: one macro call for the ceremony, the hook imported from the package, and
`Ithibati.Web.Gate` deciding who is signed in on both halves of the application.

It is deliberately plain: the generator's daisyUI, heroicons plugin and `core_components.ex` are
all removed, so that what is left is Ithibati and the Phoenix around it, and nothing else to read
past.

## Running it

Needs Postgres. Credentials are the generated defaults in `config/dev.exs`.

```
mix setup
mix phx.server
```

Then open <http://localhost:4000>, register the first account with a passkey, and follow the link
inside. No hardware needed if you would rather not: Chrome DevTools has a virtual authenticator
under *More tools → WebAuthn*.

## What to read, in this order

| | |
|---|---|
| `config/config.exs` | What Ithibati is told: your repo, your account schema, the type your `users.id` has. |
| `lib/ithibati_live/accounts/user.ex` | Your account table stays yours. |
| `priv/repo/migrations/` | Yours first, then `Ithibati.Migration.up(version: 1)`, pinned. |
| `lib/ithibati_live/auth.ex` | Who may register, what an account is made of, what a verified assertion is worth. |
| `lib/ithibati_live_web/router.ex` | `ithibati_routes/1`, the gate in the pipeline, and two `live_session`s — one open, one that refuses. |
| `lib/ithibati_live_web/live/sign_in_live.ex` | The LiveView says *when*; the hook does the round-trips. |
| `assets/js/app.js` | One import line, merged into the hooks the socket already takes. |

## Why the LiveView does not do the ceremony itself

A ceremony ends in a session cookie and a LiveView cannot set one. So the hook posts to the
endpoints over `fetch` and follows the redirect the handler answers with; the LiveView keeps what it
is good at, which is having the fields and validating them before any of it starts.

The ceremony routes have a pipeline of their own rather than sharing `:browser`, and this example
is how that came to be written down: `:browser` accepts `["html"]`, so it refused the hook's request
with a **406** before the controller was ever reached. The library's README said to use `:browser`
until this example proved otherwise.

What the ceremony pipeline does need is the session the challenge waits in and
`protect_from_forgery` — post to `/auth/registration/challenge` without the token and you get a 403,
as you should.

## One line here that a real application does not need

`config/config.exs` adds `--alias:ithibati=…` to esbuild. That is because this example depends on
the library by **path**, and Mix creates no `deps/ithibati` for a path dependency, so the bare
`import … from "ithibati"` has nothing to resolve against. Take Ithibati from Hex and the import
works with no build configuration at all — which is what the library's README says, and it is true
for everyone who is not living inside the repository.

## What this example is not

It takes one account — the first — and then refuses. That is `registration_subject/2` doing its
job; an invitation-only or open instance answers differently there.
