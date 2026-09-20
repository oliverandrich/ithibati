# Ithibati, invitation only

Nobody registers here without an invitation — except the first person, who has nobody to invite
them. The first person must enter an operator-issued code before starting a passkey ceremony.
Both answers live in one function, `registration_subject/2` in
`lib/ithibati_invites_web/auth.ex`,
where [`examples/open_registration`](../open_registration) simply answers `{:ok, username}`.

Read the two side by side. The account schema, the users migration, the ceremony routes, the hook
and the gate are the same in both; what this one adds is the machinery that decision needs — an
`invitations` table and its schema, and a page for accepting one.

## Running it

Needs Postgres. Credentials are the generated defaults in `config/dev.exs`.

```
mix setup
mix ithibati_invites.setup_code
mix phx.server
```

Then open <http://localhost:4000> (the open-registration example uses the same port, so run one at
a time, or give this one `PORT=4001`):

1. The operator command prints a code to your terminal. Enter it on the unclaimed instance,
   then pick a username and prove it with a passkey. That account claims the instance and the
   setup form never appears again. Issuing another code before the claim revokes the old one.
   Add a per-source rate limit to the public code form before exposing the application.
2. Go inside, invite somebody, and copy the link. It is shown once: the row holds the token's
   sha256, so nothing can show it to you again.
3. Open the link (a private window is easiest). It names the username the invitation was addressed
   to and does not offer to change it.

No hardware needed if you would rather not: Chrome DevTools has a virtual authenticator under
*More tools → WebAuthn*. `mix ecto.reset` deletes the development database and starts over;
use it only with disposable data.

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
| `lib/ithibati_invites_web/auth.ex` | The hinge. The first claim consumes operator authorization; an invited link is spent as it is accepted. |
| `lib/ithibati_invites_web/controllers/setup_controller.ex` | Exchanges the operator code for a short-lived session proof. |
| `lib/ithibati_invites/accounts/invitation.ex` | The invitations table is yours. Ithibati adds the invitee's identifier, the token digest, an expiry and an acceptance timestamp; what an invitation *grants* would go here. |
| `lib/ithibati_invites_web/live/inside_live.ex` | Writing one. The token exists in memory for exactly as long as this page renders. |
| `lib/ithibati_invites_web/live/invite_live.ex` | Accepting one, and why there is no field to change the name. |
| `priv/repo/migrations/` | Application tables first, then pinned Ithibati versions 1, 2 and 3 in separate migrations. |

## Three things worth noticing

**A spent or expired invitation is answered exactly like one nobody holds.** `Invitations.fetch/1`
returns `nil` for all three, so the page cannot tell a used link from an invented one, and neither
can somebody guessing.

**The acceptance is one transaction.** `Invitations.accept/2` marks the invitation spent inside the
same transaction that creates the account and its passkey, so two requests arriving together cannot
both succeed — the database decides, not a check beforehand.

**The invitee cannot rename themselves.** `accept/2` refuses an acceptance whose account carries an
identifier the invitation was not addressed to. That is why `invite_live.ex` shows the name rather
than offering a field: a field would only produce a refusal further down, and until somebody noticed
it would look like a form that hands an invitation to whoever fills it in.

## Two lines a real application does not need

`config/config.exs` adds `--alias:ithibati=…` to esbuild, and `assets/package.json` exists at all.
Both are artefacts of living inside the library: a path dependency has no `deps/ithibati` for the
bare specifier to resolve against, and Node's module resolution would otherwise walk up into the
library's own `package.json`. Take Ithibati from Hex and neither is needed.

## Optional invitation mail and open registration

This application owns a [Swoosh mailer](https://hexdocs.pm/swoosh/Swoosh.Mailer.html).
`Ithibati.InvitationMail` calls the content and delivery functions in
`lib/ithibati_invites/invitation_email.ex`. Replace the wording with your templates and configure
the application's sender and mailer adapter for real delivery. The default Local adapter only
stores messages in memory; it does not send to external mailboxes.

To enable mail in `config/dev.exs`:

```elixir
config :ithibati, :invitation_mail, enabled: true
```

Config merges keyword settings from `config/config.exs`, preserving both callback functions.
An authorized application action can send a link that it already holds:

```elixir
Ithibati.InvitationMail.deliver("ada@example.test", invitation_url)
```

To also allow visitors to request their own invitations:

```elixir
config :ithibati_invites, :open_registration, true
```

After the initial instance claim, the public page offers username and email fields. Submitting
sends the link; following it uses the existing invitation page and passkey registration.
Both switches are required. This example uses username identifiers. In an application with email
identifiers, collect one email address and use it for both the invitation identifier and delivery.
The email address is only the delivery destination in this username-based example;
it is not stored as an account identifier or a verified profile field. The mail request does not
reserve the username. Before exposing this flow publicly, add rate limits per source and recipient.

With the Local adapter you can inspect the captured messages in `iex -S mix phx.server` using
`Swoosh.Adapters.Local.Storage.Memory.all()`. The test suite uses `Swoosh.Adapters.Test` and
covers manual delivery, the public form, acceptance, disabled switches and failure paths.
The application returns a neutral public message for failed and successful requests alike;
`Registration.request_invitation/2` returns the detailed result to application callers.
