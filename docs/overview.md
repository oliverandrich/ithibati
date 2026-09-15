# Ithibati

![Ithibati](assets/logo.png)

Passkey authentication for Elixir applications: accounts, WebAuthn credentials, recovery codes and
revocable tokens. It has no opinion about what an account may do. The web half is optional and
built for Phoenix.

[Swahili, *ithibati*](https://en.wiktionary.org/wiki/ithibati): proof, evidence. In WebAuthn's own vocabulary, attestation.

Ithibati is the half of an accounts context that knows *who someone is and how they prove it*: the
account row, its passkeys, its recovery codes, its tokens. It knows nothing about what that
account may then do, and that is the point of the split. [Getting started](getting_started.md)
walks an empty Phoenix application through to a working sign-in. This page is the map of
everything else.

## Where to go next

- **[Getting started](getting_started.md)** — an empty `phx.new` application walked through to
  a working sign-in: the dependency, the schema, the migration, the handler, the routes, the
  browser hook and the recovery-codes page.
- **[Registering and signing in](ceremonies.md)** — the endpoints, the four callbacks you
  implement, the JavaScript that drives the browser, and how to do all of it without Phoenix.
- **[Passkeys](passkeys.md)** — enrolling a second device, listing, renaming, revoking, and the
  one you cannot delete.
- **[Recovery codes](recovery.md)** — for the day a passkey is gone, and the callback that
  signs somebody in with one.
- **[Invitations, and the first account](invitations.md)** — claiming an empty instance, and
  letting somebody in.
- **[`mix ithibati.doctor`](doctor.md)** — what it asks, and the questions only it can ask.
- **[Credo checks](credo.md)** — three rules a consuming project can switch on.
