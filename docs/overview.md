# Ithibati

![Ithibati](assets/logo.png)

Ithibati provides passkey authentication, recovery codes and revocable sessions for Elixir
applications. Start with [Getting started](getting_started.md) to add them to a Phoenix
application with open registration.

## How the pieces fit

Your application owns the account schema, its table and the rules for creating an account.
`Ithibati.Schema.User` adds the identifier and credential associations that Ithibati needs.
Roles, teams and permissions remain application concerns.

The identity core verifies WebAuthn credentials through `wax_`, manages passkeys and recovery
codes, and stores sessions. Verification returns an account. Issuing a session or another
credential is a separate decision made by the caller.

The optional web layer adds Phoenix endpoints, a handler behaviour, a session gate and a
LiveView browser hook. Phoenix, LiveView and Plug are taken together. The core also works
without that layer; [direct ceremonies](ceremonies.md#without-the-web-half) show the calls.

Account creation uses `Ecto.Multi`: the application inserts its account and any related rows,
then Ithibati appends the first passkey and recovery codes. Everything commits together.
Invitations follow the same arrangement: your table records what the invitation grants, and
Ithibati supplies the token and acceptance step.

## Design decisions

- **The application owns its account and invitation tables.** Ithibati supplies schema macros,
  changeset functions and checks for the columns it uses. Your application can add its own fields.
- **Verification and credential issuance are separate.** The same verified account can lead to
  a browser session, an application-owned API token or another application step.
- **The relying party is supplied per call.** The core receives `rp_id` and `origin` explicitly.
  The web layer derives defaults from your endpoint and offers a callback for other trusted
  clients. These values never come from Ithibati or `wax_` configuration.
- **PostgreSQL, SQLite and MySQL are supported.** Migrations verify existing columns and uniqueness
  constraints before adding references to application-owned tables. SQLite and MySQL require the
  [database settings and transaction handling](configuration.md#databases) described in the guide.

## Choose a guide

| Task | Guide |
| --- | --- |
| Build a working Phoenix sign-in | [Getting started](getting_started.md) |
| Change identifiers, indexes or configuration | [Configuration and schemas](configuration.md) |
| Understand database transactions, storage and migration failures | [Database behavior](databases.md) |
| Wire callbacks, routes, sessions and browser events | [Registering and signing in](ceremonies.md) |
| Add, rename or revoke a passkey | [Passkeys](passkeys.md) |
| Issue, redeem and display recovery codes | [Recovery codes](recovery.md) |
| Restrict registration to invitations | [Invitations and the first account](invitations.md) |
| Diagnose an installation | [Setup checks](doctor.md) |
| Check integration code automatically | [Credo checks](credo.md) |

The repository includes complete [open-registration](https://github.com/oliverandrich/ithibati/tree/main/examples/open_registration),
[invitation-only](https://github.com/oliverandrich/ithibati/tree/main/examples/invitation_only),
and [email-registration](https://github.com/oliverandrich/ithibati/tree/main/examples/email_registration)
applications. The email example uses one email field and a local mailbox preview. CI runs their
suites, including browser tests.
