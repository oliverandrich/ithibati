# Ithibati, email registration

One email address is both the account identifier and the recipient of the registration link.
Request the link, open it and register a passkey. The account is created only when the invitation
is accepted. This applies to every account, including the first; there is no instance-claim form.

## Run locally

Start PostgreSQL. `config/dev.exs` defaults to `postgres` / `postgres` on `localhost:5432`, using
the separate database `ithibati_email_dev`. From the repository root:

```sh
cd examples/email_registration
mise exec -- mix setup
mise exec -- iex -S mix phx.server
```

Open <http://localhost:4003>. Email delivery is already enabled in development; no extra config
switch or external mail account is needed. `PORT` can override the port.

1. Enter an email address, for example `ada@example.test`, and request the registration link.
2. Open [the local mailbox](http://localhost:4003/dev/mailbox), also linked from the start page.
3. Open the message and follow its registration link.
4. Create a passkey and save the displayed recovery codes. The account uses the normalized email.
5. Visit `/inside`, sign out and sign back in with the passkey.

The Swoosh Local adapter captures messages in memory. Nothing is sent to a real mailbox, and
restarting the application clears the captured messages. The preview route exists only in
development by default. In IEx, `Swoosh.Adapters.Local.Storage.Memory.all()` shows the same messages.

The other examples use different account policies: [open registration](../open_registration)
registers usernames directly; [invitation only](../invitation_only) has an initial instance claim
and manually issued invitations. This example reuses the same invitation and passkey APIs with
email as the identifier.

## Application boundaries

- `lib/ithibati_email/registration.ex` creates an invitation through the existing schema and
  sends its link with `Ithibati.InvitationMail`. The normalized invitation email is passed as
  the recipient; no second address is collected.
- `lib/ithibati_email/invitation_email.ex` supplies the text and HTML and adapts them to the
  application's Swoosh mailer. Templates can be rendered here without adding a template engine
  or MJML to Ithibati.
- `lib/ithibati_email_web/auth.ex` requires a valid invitation before issuing a challenge and
  again at completion. Acceptance, account, passkey and recovery codes share one transaction.
- `lib/ithibati_email_web/live/sign_in_live.ex` requests the link without starting a passkey
  ceremony. `invite_live.ex` handles the existing invitation-acceptance flow.

Existing-account, invalid-input and delivery-error requests receive the same public response.
The request function still returns detailed errors to application callers. Failed delivery leaves
an invitation pending and creates no account; another request can issue a new invitation. Old
links remain valid until accepted or expired unless the application revokes them explicitly.

For real delivery, configure `IthibatiEmail.Mailer` with a Swoosh adapter, configure any required
API client, and replace the example sender address. Production delivery defaults to disabled;
enable `config :ithibati, :invitation_mail, enabled: true` only after configuring the mailer.
Before exposing this flow publicly, add rate limits per source and recipient. A bearer link can
be forwarded; sending the email itself does not prove mailbox ownership. This example stores no
additional verified-email profile field.

## Checks

From this directory:

```sh
mise exec -- mix precommit
```

The gate compiles, checks lockfile hygiene and formatting, refuses compile-connected dependencies,
builds assets, checks the test schema with `mix ithibati.doctor`, and runs unit, LiveView and real
Chrome tests. The test database is `ithibati_email_test`; the browser server uses port 4103.
Chrome and its matching chromedriver are required, just as for the other examples. A missing or
mismatched driver fails the suite with setup instructions.

The root `mise run check` includes this example in Credo and migration checks. Root CI runs its
own example matrix entry. Run `mise run audit-email-example` from the repository root for the
independent dependency audit. The shared toolchain, local tracker and tooling choices are
explained in [CONTRIBUTING.md](../../CONTRIBUTING.md#example-application-tooling).
