# Registering and signing in

Both ceremonies run the same four steps: the browser asks for a challenge, the authenticator
answers it, the browser posts what it produced, and Ithibati verifies it. What happens after a
successful verification is yours.

## The routes

Five endpoints, wired in one call. They are all `POST`, and the paths are relative to the scope
you mount them in:

| | |
| --- | --- |
| `POST /registration/challenge` | asks your handler who this is, then mints a challenge |
| `POST /registration` | verifies what the authenticator made, then calls your handler |
| `POST /authentication/challenge` | mints a challenge naming no credential |
| `POST /authentication` | verifies the assertion, then calls your handler |
| `POST /recovery` | spends a recovery code, then calls your handler |

Under `scope "/auth"` those become `/auth/registration/challenge` and so on, which is what the
hook element's `data-` attributes carry. The suffixes are this library's rather than yours, so
there is no way to wire half a ceremony, and they are meant to stay put: changing one breaks
every mounted consumer at once.



```elixir
pipeline :ceremony do
  # Not `["html"]`. These endpoints answer JSON, and a `:browser` pipeline would refuse the hook's
  # request with a 406 before the controller is reached.
  plug :accepts, ["json"]
  plug :fetch_session
  plug :protect_from_forgery
end

scope "/auth" do
  pipe_through :ceremony
  ithibati_routes handler: MyAppWeb.Auth, rp_name: "MyApp"
end
```

Give them their own pipeline rather than your `:browser` one. Every plug in it is load-bearing.
The challenge waits in the session between the two round-trips, so something has to have fetched
one. `protect_from_forgery` is what the hook answers with the `x-csrf-token` header — a JSON body
is not exempt. And the format list is `json`, which is what these endpoints speak.

`:rp_name` is the name a passkey dialog shows. Two more options belong to a mount rather than to
Ithibati: `:user_verification`, whether the authenticator must confirm who is holding it, and
`:seconds`, how long a challenge stays acceptable. They default to `"preferred"` and sixty.

`MyAppWeb.Auth` implements `Ithibati.Web.Handler`. That is where the decisions Ithibati
deliberately does not make become yours: who may start a registration, what an account is made of
once a credential verifies, and what is issued after an assertion. A session cookie is one
answer; a bearer token for an extension or a native client is another, and choosing one for you
would rule out the other.

`/recovery` is the odd one out, and it earns its place here rather than in your own controller:
it ends where a verified assertion ends, at an account whose holder has proved who they are. It
takes a `code`, spends it, and calls `c:Ithibati.Web.Handler.recovered/3` — a separate callback
from [`authenticate/2`](`c:Ithibati.Web.Handler.authenticate/2`) because it carries a third thing,
the fresh batch that a spent *last* code
produces and that nobody can be shown twice. There is no challenge and no authenticator; the
whole exchange is one request.

### The relying party

Ithibati takes `rp_id` and `origin` per call, never from its own configuration — that is what
lets one deployment answer differently for a browser page and an extension. What the routes hand
it by default is derived from your endpoint's configured `:url`, not from the connection: behind
a proxy that terminates TLS those two disagree, and the browser signs what it saw.

[`relying_party/2`](`c:Ithibati.Web.Handler.relying_party/2`) is the optional callback that
changes it. A browser served from your own URL
wants the default, so the usual implementation adds to it rather than replacing it — the same
passkey has to keep working in the browser:

```elixir
def relying_party(_conn, {rp_id, origin}), do: {rp_id, [origin | @extension_origins]}
```

Implement it when the client's origin is not your URL. A native app's assertion arrives with the
origin of an associated domain, an extension's with the origin of the extension, and one
relying-party id serves all of them. Which of those you accept is your decision, which is why you
are asked rather than configured.

The origin may be a list, and for an extension it usually is: the same extension has a different
stable origin in each browser — `chrome-extension://<id>` and `moz-extension://<hash>` — and an
assertion carries whichever one it was made at.

**Return values from a fixed set.** If you read the `origin` request header and hand it back, the
check compares the client's claim against itself and matches whatever arrives: a credential
registered for your site could then be asserted from any page its holder visits. Nothing fails
when you get this wrong — not in production, not in your tests — because the origin always
matches.

### Getting it right in production

The default is your endpoint's `:url`, so that setting is the one that decides whether passkeys
work. For an application at `https://auth.example.com` behind a TLS-terminating proxy:

```elixir
config :my_app, MyAppWeb.Endpoint,
  url: [host: "auth.example.com", scheme: "https", port: 443]
```

which gives `rp_id` `"auth.example.com"` and origin `"https://auth.example.com"`. Three things
follow, and the last one is the expensive one:

- **The `rp_id` may be a registrable suffix of the origin's host, never anything else.** An
  application served from `app.example.com` may use `example.com` as its relying party, which
  lets a passkey work across `app.` and `admin.`; it may not use `example.org`, and the browser
  refuses the ceremony if it tries.
- **`www.example.com` and `example.com` are two relying parties**, as far as an authenticator is
  concerned. Pick one and redirect the other, the way you would for cookies.
- **Changing the relying-party id invalidates every passkey ever registered.** They are bound to
  it. Moving from `example.com` to `example.dev` is not a redirect and a DNS change — every
  account has to enrol again, and recovery codes are how they get in to do it. If you might
  move, registering under the apex from the start is the cheap insurance.

One property of the ceremony is easy to lose: a challenge is single-use, and **spending it is
the caller's**. The routes do it — `Ithibati.Web.PasskeyController` deletes the challenge from
the session the first time a verification is attempted, succeeded or not — because a challenge
lives wherever the caller put it and nothing in `Ithibati.Identity.Passkeys` can reach it there.
Drive the ceremony yourself and that becomes yours to do.

### What a refusal says

Every failure reaches the browser as `{"error": "<code>"}` with a 4xx, and the hook pushes it to
your LiveView as `ithibati:failed` with that code **as a string** — your handler's atoms are
stringified on the way out. Turning them into sentences is yours; a library that shipped the
wording would be choosing the tone of somebody else's product.

What Ithibati itself can send:

| Code | Means |
| --- | --- |
| `no_credentials` | nobody has enrolled a passkey on this instance yet |
| `no_challenge` | the session holds no challenge — it expired, or was already spent |
| `malformed_credential` | the posted credential is not the shape WebAuthn describes |
| `not_discoverable` | the authenticator kept the credential to itself, so sign-in could never find it |
| `unknown_credential` | the assertion names a credential this instance does not have |
| `no_attested_credential` | the attestation carried no credential to store |
| `credential_id_too_long` | longer than the column takes |
| `already_enrolled` | that authenticator is already on an account |
| `invalid_code` | a recovery code nobody holds, or one already spent — deliberately the same answer |
| `verification_failed` | the catch-all, when a step answered something that is not an atom |

The browser half adds `ceremony_cancelled` when somebody dismisses the passkey prompt,
`ceremony_failed` for any other `DOMException`, `http_<status>` when an endpoint answers
something unexpected, and `missing_data_<attribute>` when the hook element is missing one of the
five URLs it reads.

Anything else is a code **your** handler returned. Those are yours to name and yours to phrase.

## Who is signed in

`Ithibati.Web.Gate` answers that on a plain connection and in a LiveView, from one module,
because two answers that drift apart is the failure this shape exists to prevent.

```elixir
pipeline :browser do
  plug :fetch_session
  plug Ithibati.Web.Gate, :current_account
end

live_session :admin, on_mount: [{Ithibati.Web.Gate, {:require_account, to: ~p"/sign-in"}}] do
  live "/admin", AdminLive
end
```

There are two modes and no others. `:current_account` assigns `@current_account`, or `nil`, and
always continues. `:require_account` refuses when there is nobody: the plug redirects if you give it `:to` and
answers `401` if you do not, which is what a cookie-authenticated API route wants. Both modes
read the session and nothing else. A route behind a bearer header is a plug of yours, reading
the `authorization` header and answering for itself. The `on_mount` requires `:to`, because a LiveView that halts with nowhere to send a person is a dead end.

An unrecognised mode raises where it is written. A gate that listed its modes and let anything
else through would turn a typo into a page that refuses nobody, which is protection that never
fails visibly.

### Signing in and out

`Gate.log_in(conn, account)` is what a handler's `authenticate/2` usually ends with. It stores a
session token under Ithibati's key, after renewing the session against fixation.

[`Gate.log_out/1`](`Ithibati.Web.Gate.log_out/1`) revokes the token rather than merely forgetting
it, so a copied cookie stops
working for new requests and new mounts. It also ends the sockets that session opened, so a
LiveView left running in another tab does not go on answering as somebody who signed out. That
second half needs two things a `mix phx.new` application already has: a `:pubsub_server` on your
endpoint, and the live socket declared with the session in its `connect_info`:

```elixir
socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [session: @session_options]]
```

That session is where LiveView looks for the socket's `id`. Without the pubsub server the gate
writes no socket id and says nothing, and you are back to the first half alone. Without the
`connect_info`, nothing subscribes and the broadcast reaches nobody — no error, just a socket
that outlives its session.

Signing in clears the session and the CSRF token with it, so **the flow has to end in a full page
load**. Answer from your handler with `%{redirect: …}` and the hook follows it. A page that stays
put after signing in holds a token the new session has never heard of, and its next form post is
refused.

Neither function is imposed. A handler issuing a bearer token for an extension calls neither, and
the gate then finds nobody, which is the right answer.

The gate is about authentication and stops there. What an account may **do** is your question.

### The table underneath

`Ithibati.Identity.Sessions` is what the gate calls, and an application rarely calls it directly:

```elixir
alias Ithibati.Identity.Sessions

Sessions.generate_session_token(account)   # the plaintext, once
Sessions.get_user_by_session_token(token)  # the account, or nil
Sessions.delete_session_token(token)       # revoke it
```

The row holds the token's sha256 and nothing else that could sign anybody in, so a database dump
is not a set of live sessions. `get_user_by_session_token/1` answers `nil` for every way there is
not to have one: unknown, revoked, older than the configured validity, and `nil` itself, which is
what a missing session key gives you.

A session lasts sixty days unless you say otherwise:

```elixir
config :ithibati, session_validity: {30, :day}
```

The units are `:second`, `:minute`, `:hour`, `:day` and `:week`. `:month` and `:year` are missing
because neither has a fixed length, and a validity that moves with the calendar is not what
anybody means by ninety days. A value this library cannot read is refused where a session is
minted and where one is read, so a broken setting fails at the sign-in rather than quietly
letting everybody stay signed in forever. A page nobody is signed in to is unaffected.

There is no "sign out everywhere". `delete_session_token/1` revokes the one token you hand it,
and ending an account's other sessions means deleting its rows:

```elixir
MyApp.Repo.delete_all(Ecto.assoc(account, :sessions))
```

`Ithibati.Credo.NoDirectTableAccess` leaves that line alone, because it reaches the rows
through an association on an account this library handed you rather than through the table.
Naming the schema — `delete_all(Ithibati.Session)` — is what the rule reports.

This table holds sessions and nothing else. An API token for an extension or a native client is a
different object, and building it is yours or another library's.

## The JavaScript

The ceremonies need a little client code: the browser's API wants buffers where Ithibati sends
unpadded base64url, and it hands back a credential that has to be serialised the way the
verifications expect. That code is `priv/static/ithibati.js`.

There are two ways to reach it. They differ in one string and both register the same hook name.

The hook talks to the endpoints [`ithibati_routes/1`](`Ithibati.Web.Router.ithibati_routes/1`)
generated, and reads their paths off the
element, because you chose the scope they are mounted under:

```heex
<div
  id="sign-in"
  phx-hook="Ithibati.Web.Hooks.PasskeyCeremony"
  data-registration-challenge-url={~p"/auth/registration/challenge"}
  data-registration-url={~p"/auth/registration"}
  data-authentication-challenge-url={~p"/auth/authentication/challenge"}
  data-authentication-url={~p"/auth/authentication"}
  data-recovery-url={~p"/auth/recovery"}
></div>
```

Set the pair for each ceremony that element starts. A missing one is reported as
`missing_data_registration_url` rather than as a ceremony that failed.

Push `ithibati:register`, `ithibati:authenticate` or `ithibati:recover` from your LiveView to
start one — that is where the identity fields are and where you have validated them. The hook pushes back
`ithibati:done` with whatever your handler answered, or `ithibati:failed` with a reason. The one
answer it acts on itself is `%{redirect: …}`: a handler that sends somewhere, such as the page
that shows the recovery codes, is obeyed rather than reported. Everything in between is a `fetch`
to the endpoints rather than a LiveView event, because signing in ends in a session cookie and
only a controller can set one.

This half runs on somebody else's machine, so it is driven rather than described. Both example
applications carry Wallaby feature tests in `test/features/` that put this file in a real browser
against a real WebAuthn ceremony, including the reasons the hook distinguishes when one does not
finish. They are part of each example's own `mix test`, so CI runs them on every push. Chromium
only: the virtual authenticator is Chrome DevTools Protocol's, which is the one that hands the
page a credential real enough for `toJSON()`.

**From the package**, which always works. The specifier is bare because Ithibati ships a
`package.json`, the same way `phoenix` and `phoenix_live_view` do, and a Phoenix 1.8 application
already has `deps` on esbuild's `NODE_PATH`:

```javascript
import {hooks as ithibatiHooks} from "ithibati"

let liveSocket = new LiveSocket("/live", Socket, {hooks: {...ithibatiHooks}})
```

**From the colocated manifest**, if you would rather LiveView kept track of it. Set
`ITHIBATI_COLOCATED_HOOKS=1` in the environment that builds your project, so that Ithibati runs
LiveView's compiler and writes the manifest:

```javascript
import {hooks as ithibatiHooks} from "phoenix-colocated/ithibati"
```

Then build Ithibati again with `mix deps.compile ithibati --force`. Mix does not rebuild a
dependency because an environment variable changed, and the manifest is only written while
compiling — without that step the import resolves to nothing and the bundler says so without
saying why.

If you are not using LiveView, import `register` and `authenticate` from the same package instead
of the hook. They take the options Ithibati produced, drive `navigator.credentials`, and return
what the verifications expect.

## Without the web half

Everything above is Phoenix, which is the ordinary case. Without it the ceremony is the same
calls; what the routes add is the HTTP around them, somewhere to keep the challenge, and a
handler to dispatch to. You now pass the relying party yourself, where the routes were deriving
it from your endpoint. This is the route for a native client, a browser extension, or a server that is
not Phoenix, and it is a first-class route rather than an afterthought.

Registering, with `alias Ithibati.Identity.Passkeys`:

```elixir
challenge = Passkeys.registration_challenge(rp_id, origin, user_verification: "preferred")
options = Passkeys.registration_options(challenge, identifier, rp_name: "MyApp")
# hand `options` to the client, and keep `challenge` until its answer arrives

{:ok, key_attrs} = Passkeys.verify_registration(credential, challenge)
{:ok, _key} = Passkeys.add_key(account, key_attrs)
```

An account that does not exist yet is created in one transaction with its first passkey and its
recovery codes; [Invitations, and the first account](invitations.md) shows that composition.

Signing in:

```elixir
{:ok, challenge} = Passkeys.authentication_challenge(rp_id, origin)
options = Passkeys.authentication_options(challenge)

{:ok, account} = Passkeys.verify_authentication(credential, challenge)
```

[`authentication_challenge/3`](`Ithibati.Identity.Passkeys.authentication_challenge/3`) answers
`{:error, :no_credentials}` on an instance where nobody has
enrolled one, which is the case a sign-in page has to say something about.

Three things the controller does that are now yours:

- **Keep the challenge between the two requests.** The controller puts it in the session. A
  client that has no cookie needs something else — a row, a cache entry, or a signed value it
  hands back — and whatever it is has to be spent once and not replayable.
- **Decide what a verification issues.**
  [`verify_authentication/2`](`Ithibati.Identity.Passkeys.verify_authentication/2`) answers the
  account and stops there. `Ithibati.Identity.Sessions.generate_session_token/1` is one answer,
  and it is the only one this library has. A bearer token for a device is yours to mint, store
  and revoke.
- **Pass the relying party per call.** They are arguments, not configuration, so one deployment
  can serve a browser page and an extension with different answers. Per call does not mean *from
  the request*: choose from a set you decided in advance, the way `relying_party/2` does above.
  Reading the `origin` header and handing it back makes the check compare the client's claim
  against itself. `origin` may be a list, and for a client that is not a browser page it usually
  is.

The client half needs no framework either: `register` and `authenticate` are exported from
`priv/static/ithibati.js` alongside the LiveView hook, which is a wrapper around them. They take
the options these calls produced and return what the verifications expect.
