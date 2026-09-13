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

The three tables that *are* the library's — named below — carry a foreign key to whichever table
the macro was used in. That table name is therefore configuration
too, resolved once when the migrations are generated, and so is the **type** of that key: the
reference implementation is `binary_id` throughout, and a consumer with `bigserial` accounts would
otherwise be handed a migration that does not fit. Configuration and reality can still disagree —
nothing stops an application from naming a type its own accounts table does not have — so the
migration verifies the configuration against the database before it builds anything, and refuses
rather than leaving half a schema behind.

Four questions followed from this decision. Three are settled, and the answers belong here rather
than in the code that implements them.

**The tables this library owns are `ithibati_keys`, `ithibati_recovery_codes` and
`ithibati_tokens`** — three, not the five the reference implementation's accounts context manages.
Links are profile and belong to the consumer. A handle reservation exists so an old
`@handle@domain` cannot come to name somebody else, which is federation, and also the consumer's,
even though it is reached from the account changeset. The prefix is configurable and prefixed by
default for a reason an application does not have: `phx.gen.auth` generates `users_tokens` in the
same database, one character from `user_tokens`, and `recovery_codes` is a name anybody might have
taken.

**The migration is code, not a file.** `Ithibati.Migration.up/1` and `down/1`, called from an
ordinary migration the consumer writes in their own `priv/repo/migrations`. A static template
cannot be parametrised by the three things this decision makes configuration, and a generator task
that fills its blanks is a second mechanism doing the same job. It is versioned the way `oban`
versions its own: a table added in a later release reaches a consumer as a *second* migration
calling the same module, saying which version it starts from. What has already been applied is
recorded where Ecto records it, in the consuming application's own `schema_migrations`; this library
keeps no second copy of that. A consequence worth stating: `priv/` never has to exist in this repository, which
removes a standing hazard, because anything placed there is published and the test suite's own
migrations must not be.

**The macro contributes one field, three associations and three functions.** The field is the one
the application names — there is no default. A library that never sends mail has no business
requiring an address: that would be a personal detail collected and never used, and an application
that identifies people by username should be able to say so rather than work around an assumption.
`format:` is optional beside it, and the pattern for an address is *offered* as
`Ithibati.Schema.User.email_format/0` rather than imposed.

That pattern is the one the HTML specification publishes for `<input type=email>`, not RFC 5322 or a
parser of it. An identifier here is a credential rather than a mailbox, so there is no deliverability
to protect, and the full grammar accepts quoted local parts with spaces in them — a hazard rather
than a feature. It also does not demand a dot in the domain, because `you@localhost` is a real
address on a self-hosted instance.

**The unique index on that column is the library's to create, not the application's to remember.**
Account lookup is `Repo.get_by/3`, which raises on a second match rather than signing anybody in — so
the index is a requirement, and a requirement somebody can forget is the arrangement this document
rejected for the bootstrap guarantee. `constraint_name:` is the opt-out and names the index an
application maintains itself, which is the case where the shape is genuinely theirs: partial,
expression, `citext`, composite with a tenant column.

Whatever the field is called, values written through the library's changeset are trimmed and
lowercased. That is what makes a plain unique index refuse a capitalisation of a name somebody already has, with no functional index for an
application to remember; a capitalisation worth keeping is a display concern, and display belongs to
the application.

Nothing else comes across: not `superadmin`, which is authorization and whose granting becomes a step
the application composes into the same transaction, and not any of the profile the reference
implementation keeps on an account.

**That an instance has been set up is a row in a table of this library's, not a flag on an account.**
The first draft put a boolean on the application's own table with a partial unique index beside it,
which the application had to remember to create — and forgetting it fails nothing until two people
register at the same moment. Measured in the reference implementation: nothing ever *reads* that
flag. Its entire value is the index. So the index moves to a table `Ithibati.Migration.up/1` creates,
where it cannot be forgotten.

The deciding argument is not the forgetting, though. A boolean on an account conflates *this instance
has been set up* with *this account set it up*: delete that account and both facts vanish, and a
second setup becomes possible. A row whose `user_id` is nilified on delete says the true thing — set
up, by nobody who is still here — and that is not expressible as a column.

**The name a passkey dialog shows is derived by this library, not supplied by the application.**
`passkey_display_name/1` may answer `nil`, and answering `nil` is correct; the fallback to the
identifier belongs here. An overridable function that had to carry its own fallback put that
correctness in a sentence of documentation instead, which is where it was first got wrong. And the
very first registration on an instance has no account to call anything on, so the derivation takes
an identifier directly in that case.

One question remains open, and it will otherwise be settled by accident while the code is being
moved:

- **How the library announces a change.** The code being moved broadcasts over `Phoenix.PubSub`
  with a hardcoded server name, while Phoenix here is an optional dependency — so the core would
  not compile without it. Following decision 3, notification should become the consumer's step, the
  way the content and media calls already did.

## 3. `Ithibati.Identity.*` may not name another context

The portable half is portable only for as long as nothing reaches out of it. In the reference
implementation that was true by accident once and stopped being true twice: deleting an account
reached into the content context to rewrite the author's posts, and removing an avatar reached into
the media context to drop a file. Both became the caller's step, and a Credo check — an AST walk,
allow-listing rather than forbidding — is what keeps a third from appearing.

It guards the `Ithibati.Identity` **namespace**, not one file: the behaviour lives in
`Ithibati.Identity.Passkeys`, `Ithibati.Identity.Tokens` and whatever joins them, and a check that
listed module names would leave the next one unguarded until somebody remembered to add it. A
prefix covers it by construction, which is the direction that matters — forgetting an allow-list
entry is loud, forgetting to guard a module is silent.

That check comes across with the code, and it comes across *first*: a rule nothing enforces is a
rule that quietly stops being true.

## 4. A grant is `Ecto.Multi` composition, not an event

When an invitation is accepted, an account, its first passkey, its recovery codes and the
application's own record of what the account may do are all created at once. That is one
transaction or it is a bug: an account that exists with no membership is a person who can log in and
see nothing, and an account that half-failed is worse.

So the library hands out composable `Ecto.Multi` fragments — `with_key_and_codes/3`
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

- **Verification does not mint a credential.** `verify_authentication/2` returns the account. What
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

  Two things follow that are easy to miss. `wax_` fills any option it was not given from
  `config :wax_`, so this property rests on the library passing both explicitly — which a test now
  pins by setting those keys to a wrong value and proving the per-call value wins. The same applies
  to every other option the library's behaviour depends on; see decision 7. And the relying party has a
  *third* field: `rp_name`, the name a passkey dialog shows. That one is genuinely the application's
  identity, so it is either a config key or a fourth argument — but it must be chosen, not
  inherited.

What follows from that, and what does not:

- **Decided now**, because a published function signature costs a major version to change and a
  column does not: the token functions become general before the first release, not after. `generate_token(user, context)` with
  `generate_session_token/1` as the convenience over it, and the same generalisation for lookup and
  revocation.
- **Decided now**, and a departure from the reference implementation, which stores the secret as
  `phx.gen.auth` does: the row carries the token's **sha256**, and the secret is handed to the
  caller once. The table is about to hold bearer tokens for an extension and a native app — longer
  lived than a session cookie and copied to more places — and a digest at rest costs one hash per
  lookup while making a database dump, or a read-only injection, useless for logging in. The column
  is named `token_hash` so that nothing reads as if it held the secret, and what is handed out is
  the URL-safe encoding of the 32 bytes rather than the bytes: raw bytes cannot go in an
  `authorization` header at all, and the reference implementation never noticed because a Plug
  session cookie encodes the whole payload for it.
- **Not now**: no speculative columns (a device label, a last-used timestamp), no scopes, no
  OAuth2, no device-authorization flow. Each of those is additive, and inventing them against no
  real client produces the wrong shape.
- **Recommended to consumers**: mint the credential on a real web page even when the client is not
  one. An extension opening a normal page once, and receiving a token, sidesteps the origin
  question entirely. Native passkeys, with their associated-domain files, are worth it for an app
  and are opt-in.

## 6. No authenticator name data ships with this library

A passkey could be labelled with the product it lives in — "1Password", "YubiKey 5 Series" — by
mapping the AAGUID an authenticator reports to a name. This library does not do that, and does not
ship, download or bundle any such list.

The reason is not taste. The list every implementation uses is
`passkeydeveloper/passkey-authenticator-aaguids`, which **declares no licence**: asked three times
between 2023 and 2025 to add one, the maintainer closed the last two as *not planned* — "there are
no current plans to add a license as it will be going away shortly" — and answered the direct
question about embedding with "it is dynamic and is not intended to be embedded anywhere". The
repository's own README says its contents will one day be replaced by an empty object. The
authoritative alternative, FIDO's Metadata Service, carries usage terms embedded in every BLOB that
have to be agreed to.

So: no licence, against the author's stated intent, and a source that is going away. Under German
law the database right in §87a UrhG applies to a curated collection like this independently of any
creative height, which is exactly the case it exists for.

The consequence reaches further than the data. Requesting `direct` attestation is what makes an
authenticator disclose its AAGUID at all; without the label there is nothing to do with it, so
registration asks for `attestation: "none"`. That is the better default anyway — `direct` can carry
a certificate identifying the authenticator model, and some platforms ask the person to consent to
sending it. Asking for something and then not policing it is worse than not asking.

A label still exists: whatever the browser reported, or "Passkey". An application that wants product
names can map them itself, having read the terms of whichever list it chooses.

## 7. The core builds what the browser reads, and which WebAuthn choices are whose

`registration_options/3` returns the browser's `PublicKeyCredentialCreationOptions` — camelCase
keys, unpadded base64url, the works — from the portable half, not from the optional web half.

That looks like a layering mistake and is not. The web half is optional by design (decision 3's
boundary is `lib/ithibati/web/`), so a consumer who wires its own controller still needs these
options, and what they would most likely get wrong is exactly what lives here: unpadded base64url
rather than standard, the legacy `requireResidentKey` spelling beside the modern one, and asking
for the `credProps` extension at all. What the web half owns is the transport — routes, JSON
serialisation, the hook that calls `navigator.credentials`. The shape of the dictionary is a
protocol detail, and protocol details are what this library is for.

**The inbound direction is the same argument, so it takes the same shape.** The verifications take
the `PublicKeyCredential` the browser produced, parsed — `"id"`, `"response"`, and
`"clientExtensionResults"`, exactly as `toJSON/0` serialises them — and decode the base64url
themselves. A consumer hands over what arrived and nothing else. The alternative, loose binaries in
a fixed order with the decoding left outside, puts unpadded base64url in the caller's hands and
makes two transposed fields indistinguishable from a genuinely bad assertion: same type, same
arity, same refusal. Whether a credential is discoverable comes from the same map for the same
reason — it is where the browser puts it, so there is no wrong value to pass.

**A registration must produce a discoverable credential.** Sign-in names no credential (decision 5
explains why), so a credential the authenticator keeps to itself would be invisible there, and the
person would find out at their next visit, where the platform says "no passkey available" and
nothing explains it. The library therefore asks for `residentKey: "required"` *and*
`requireResidentKey: true` — one wish in two spellings, because a client implementing only
WebAuthn L1 ignores the first — asks for `credProps`, and refuses a registration whose client
answers that it stored something else. This is a constraint a consuming application inherits: there
is no option to turn it off, because a sign-in that names no credential cannot work without it.

**Everything else the library's behaviour depends on is passed to `wax_` per call**, never left to
`config :wax_`: the relying party, the attestation conveyance, the attestation types trusted, how
long the ceremony may take, whether the user must be verified, and — on the sign-in side —
`silent_authentication_enabled`, which accepts an assertion made without the person being
present. An option not passed is one a
consumer can change from a distance without knowing what it disagrees with — a
`trusted_attestation_types` without `:none` refuses every registration this library can produce.

**Two of those are the application's to decide, and are options rather than constants:** whether the
authenticator must verify who is holding it, and how long a challenge stays acceptable. Both have
defaults (`"preferred"` and sixty seconds) and both are read back off the challenge when the
browser's options are built, so the two sides cannot disagree — a disagreement there is silent and
looks like a broken authenticator.

**A sign-in names no credential.** `allowCredentials` is sent empty rather than filled with the
ids this deployment knows. Naming them would turn a discoverable-credential sign-in into one
restricted to those ids: the platform routes straight to whoever holds one and never offers a
chooser, so a second authenticator could never be picked — and this runs unauthenticated by
necessity, so every id it named would be readable by anyone who opened the page. It is the sign-in
counterpart of requiring a discoverable credential at registration, and a consumer wiring its own
controller must not reverse it.

**Two properties this library cannot hold for a consumer, and says so rather than leaving them to
be discovered.** A challenge is single-use, and it lives wherever the caller put it — so deleting it
on the first verification is the caller's step; nothing here can tell a replayed assertion from a
first one. And the signature counter is neither stored nor compared: it exists to detect a cloned
authenticator, and a synced passkey reports zero forever, so a comparison either says nothing or
locks out the person whose credential moved between devices.

Inside this project the caller that holds the first of those is the web half: its endpoint deletes
the challenge the first time it verifies one, success or failure.

**The algorithms offered are ES256 and RS256.** Ed25519 is absent deliberately rather than
forgotten: no authenticator in circulation offers it and neither of these two, and a list a consumer
can extend is a published option with no caller yet. If one appears, it becomes an option like the
two above.
