# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

A release that raises the database schema version says so here and names the new number, because
that is the one thing you have to act on: it means writing a migration of your own that calls
`Ithibati.Migration.up(from: <old>, version: <new>)`.

## Unreleased

## [0.1.1] - 2026-09-16

Documentation only. Nothing the library does has changed.

### Changed

- The README, the guides, the moduledocs and the comments read more plainly.
- The documentation site carries an OpenGraph image, so a link to it shows a card.

### Fixed

- Four comments that described the code wrongly: `Ithibati.Config`'s repo check named an error
  that would never appear, `Ithibati.Doctor`'s callback list was described as read from the
  behaviour when it is a hand-written copy, and two counts were off by one.

## [0.1.0] - 2026-09-15

First release. Ithibati answers who someone is and how they prove it, and nothing about what
their account may then do.

### Added

- Passkey registration and authentication (WebAuthn, through
  [`wax_`](https://hex.pm/packages/wax_)), including the first account on an empty instance, and
  enrolling further credentials on an account that already has one.
- Single-use recovery codes, which refill themselves when the last one is spent.
- Revocable server-side sessions. The cookie carries the secret, the row carries its sha256,
  and signing out revokes the row. `config :ithibati, session_validity:` says how long one
  lasts, and defaults to sixty days.
- Invitations, optional: Ithibati owns the token, its expiry and the redemption; the application
  owns the table and whatever the invitation grants. `Ithibati.Migration.invitation_columns/1`
  writes the four columns it needs into a `create table` of yours, and
  `Ithibati.Migration.invitation_index/1` the unique index, for an application turning
  invitations on after the migration has already run. The migration checks the columns and their
  types either way — a `token_hash` written `:string` is refused at migrate time rather than at
  the first invitation.
- Schema macros for the account and the invitation table, so the application keeps both.
- `Ithibati.Migration`, called from a migration of your own rather than copied from a template.
- An optional Phoenix layer: the ceremony routes, a gate that denies by default, and a LiveView
  hook. Phoenix, LiveView and Plug are optional dependencies, taken or left together.
- `mix ithibati.doctor`, twelve checks on a setup, runnable from your own gate. Two of them
  catch what compiles and migrates anyway: an invitation table whose `token_hash` has no unique
  index, and a handler missing one of the four callbacks.
- Signing in with a recovery code: a fifth route, `POST /recovery`, ending in a `recovered/3`
  callback on your handler. It is separate from `authenticate/2` because it carries the fresh
  batch a spent last code produces, which is the only copy of it there will ever be.
- Three Credo checks a consuming project can switch on.
- The migration refuses a table that is missing the column it indexes — your identifier column,
  or an invitation table's `token_hash` — and says where the column belongs, rather than failing
  with Postgres's `undefined_column`.

[0.1.1]: https://github.com/oliverandrich/ithibati/releases/tag/v0.1.1
[0.1.0]: https://github.com/oliverandrich/ithibati/releases/tag/v0.1.0
