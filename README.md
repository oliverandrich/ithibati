# Ithibati

Passkey authentication for Elixir applications — accounts, WebAuthn credentials, recovery codes and
revocable tokens — without an opinion about what an account may do. The optional web half is for
Phoenix.

Swahili, *ithibati*: proof, attestation.

> **Status: nothing is released and nothing works yet.** See [CHANGELOG.md](CHANGELOG.md).

## What it is

Most authentication libraries answer two questions at once: *who is this* and *what may they do*.
The second answer is where every application differs — sites, tenants, teams, roles, invitations —
and it is why the first answer so rarely gets reused.

Ithibati will answer only the first:

- passkey registration and authentication (WebAuthn, via [`wax_`](https://hex.pm/packages/wax_)),
  including the bootstrap case of the very first account
- recovery codes, single-use, for the day a passkey is gone
- revocable server-side tokens — a session behind a cookie, a device token behind a bearer header,
  the same row with a different context
- the changeset pieces and the composable `Ecto.Multi` fragments to hang your own steps on

Your application keeps its own `users` table, its own roles and its own invitations, and composes
the grant into one transaction with the library's half.

## Design

Five decisions shape it, and [`docs/design.md`](docs/design.md) carries each one with its reasoning:

1. [The name](docs/design.md#1-the-name)
2. [The application owns the `users` table](docs/design.md#2-the-application-owns-the-users-table)
3. [`Ithibati.Identity` may not name another context](docs/design.md#3-ithibatiidentity-may-not-name-another-context)
4. [A grant is `Ecto.Multi` composition, not an event](docs/design.md#4-a-grant-is-ectomulti-composition-not-an-event)
5. [Non-browser clients ride on the token, not on OAuth2](docs/design.md#5-non-browser-clients-the-token-is-the-boundary-not-oauth2)

## Licence

MIT — see [LICENSE](LICENSE).
