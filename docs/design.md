# Design

Ithibati is the half of an accounts context that knows *who someone is and how they prove it* —
the account row, its passkeys, its recovery codes, its tokens. It deliberately knows nothing about
what an account may *do*: roles, tenancy, memberships, invitations stay in the application.

The reference implementation is [Chapisho](https://github.com/oliverandrich/chapisho), a
self-hostable blog engine, where this code was written first and where a Credo check already kept
it from naming another context. Chapisho becomes consumer number one, which makes the extraction a *move*
rather than a copy — there is no second copy to drift.

## 1. The name

Swahili, `ithibati` — proof, attestation. A noun for what the library does, following the same
rule the reference implementation's own name follows: name the thing, do not reach for a picture of
it. Checked free on Hex and on GitHub before it was chosen, including a search for repositories
whose *name* matches, because a collision in another BEAM language is still a collision for the
person searching.

## 2. The application owns the `users` table

Ithibati contributes a schema macro, `use Ithibati.Schema.User`, rather than owning an
`auth_users` table of its own.

The alternative — a thin table the library owns, plus an application profile table pointing at it —
is the cleaner boundary and was rejected on cost. In the reference implementation the account row
carries `email, handle, name, bio, avatar, theme, locale, superadmin` plus links and memberships;
exactly one of those is the library's business. Splitting the row would put a join under post
authorship, the Fediverse actor, the byline, the avatar and the account list — an application-wide
rewrite in exchange for a boundary nobody was going to cross anyway.

So: the application declares the schema and owns the table. The macro contributes the fields the
library reads, the changeset pieces that validate them, and the constraint names it relies on. The
library is told which module that is, and which repo to use, through configuration.

The three tables that *are* the library's — `user_keys`, `recovery_codes`, `user_tokens` — carry a
foreign key to whichever table the macro was used in. That table name is therefore configuration
too, resolved once when the migrations are generated, and so is the **type** of that key: the
reference implementation is `binary_id` throughout, and a consumer with `bigserial` accounts would
otherwise be handed a migration that does not fit.

Four things this decision does *not* yet settle, and each of them will otherwise be settled by
accident while the code is being moved:

- **Which columns the macro contributes, by name.** "Exactly one is the library's business" is the
  shape of the answer, not the answer. `avatar_path` is written by the code being moved, and
  `superadmin` and `bootstrap` are authorization — the thing this library says it does not know
  about. The proposal: the *check* stays (whether this is the first account is a question about
  identity), and *granting* the role becomes a step the consumer composes in, which is what
  decision 4 provides for anyway.
- **Whether `user_links` and `handle_reservations` come along.** The paragraph above names three
  tables; the file being moved manages five. Links are profile and almost certainly the consumer's.
  A handle reservation exists so an old `@handle@domain` cannot come to name somebody else, which
  is a federation concern and probably the consumer's too — but it is reached from the account
  changeset, so saying so is not enough.
- **How the library announces a change.** The code being moved broadcasts over `Phoenix.PubSub`
  with a hardcoded server name, while Phoenix here is an optional dependency — so the core would
  not compile without it. Following decision 3, notification should become the consumer's step, the
  way the content and media calls already did.
- **What form the library's own migration takes.** A static file under `priv/` cannot be
  parametrised, and the two things named above — the table's name and its key type — are exactly
  what it would have to be parametrised by; a template plus a generator task is a second mechanism
  doing the same job. The proposal is the shape `oban` uses: a module in `lib/` with `up/0` and
  `down/0` taking those two as options, invoked from a migration the consumer writes in their own
  `priv/repo/migrations`. It also means `priv/` never has to exist here, which removes a standing
  hazard — anything placed there is published, and the test suite's own migrations must not be.

## 3. `Ithibati.Identity` may not name another context

The portable half is portable only for as long as nothing reaches out of it. In the reference
implementation that was true by accident once and stopped being true twice: deleting an account
reached into the content context to rewrite the author's posts, and removing an avatar reached into
the media context to drop a file. Both became the caller's step, and a Credo check — an AST walk
over the one guarded file, allow-listing rather than forbidding — is what keeps a third from
appearing.

That check comes across with the code, and it comes across *first*: a rule nothing enforces is a
rule that quietly stops being true.

## 4. A grant is `Ecto.Multi` composition, not an event

When an invitation is accepted, an account, its first passkey, its recovery codes and the
application's own record of what the account may do are all created at once. That is one
transaction or it is a bug: an account that exists with no membership is a person who can log in and
see nothing, and an account that half-failed is worse.

So the library hands out composable `Ecto.Multi` fragments — `Ithibati.Identity.with_key_and_codes/3`
in the reference implementation — and the application composes its own steps into the same
transaction before running it. Publish/subscribe events are for *notification* after the fact, never
for carrying a step of the grant. An event can be missed; a transaction cannot be half-applied.

## 5. Non-browser clients: the token is the boundary, not OAuth2

A browser extension, a native app or a CLI has to authenticate too, and the answer is not OAuth2 —
not for the clients that matter here.

The distinction that decides it is **first-party versus third-party**. An extension and an app the
same person ships alongside the server are first-party: there is no consent to obtain and no client
secret that could be kept anywhere safe. OAuth2 exists for the other case, a stranger's client
asking for access to a user's account on someone else's server, and it is a layer *on top of* what
follows, never a replacement for it. An authorization code flow ends by inserting exactly the token
row described below.

Three properties make this an addition rather than a rewrite, and all three are already true of the
code being moved here — verified against the reference implementation, not assumed:

- **Verification does not mint a credential.** `verify_authentication/5` returns the account. What
  is then issued — a session token behind a cookie, a long-lived device token behind a bearer
  header — is the caller's decision, taken in a separate call.
- **The token row carries a context.** One table, one shape, distinguished by a column. A device
  token is not a new kind of record; it is the same record with a different word in it.
- **The relying-party id and the origin are per-call parameters**, derived from the request, not
  library configuration. This is the property most at risk while the code is being moved, because
  consolidating two parameters into a config key looks exactly like tidying up. It is not: a native
  app's assertion arrives with the origin of an associated domain, an extension's with the origin of
  the extension, and one relying-party id serves all of them. The application decides which origins
  it accepts; the library is told, per challenge.

  Two things follow that are easy to miss. `wax_` reads `config :wax_, origin:`/`rp_id:` as its own
  defaults, so this property rests on the library always passing both explicitly — worth a test that
  sets those keys to a wrong value and proves the per-call value wins, and worth deleting the keys
  from the reference implementation rather than carrying them along. And the relying party has a
  *third* field: `rp_name`, the name a passkey dialog shows. That one is genuinely the application's
  identity, so it is either a config key or a fourth argument — but it must be chosen, not
  inherited.

What follows from that, and what does not:

- **Decided now**, because a published function signature costs a major version to change and a
  column does not: the token functions become general before the first release, not after. `generate_token(user, context)` with
  `generate_session_token/1` as the convenience over it, and the same generalisation for lookup and
  revocation.
- **Not now**: no speculative columns (a device label, a last-used timestamp), no scopes, no
  OAuth2, no device-authorization flow. Each of those is additive, and inventing them against no
  real client produces the wrong shape.
- **Recommended to consumers**: mint the credential on a real web page even when the client is not
  one. An extension opening a normal page once, and receiving a token, sidesteps the origin
  question entirely. Native passkeys, with their associated-domain files, are worth it for an app
  and are opt-in.
