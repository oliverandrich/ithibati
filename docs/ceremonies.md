# Registering and signing in

A passkey ceremony has four steps: request a challenge, ask the authenticator to answer it,
post the credential, and verify it. Ithibati handles these steps; your application decides
who may register and what to do with the verified account.

For a complete application, start with [Getting started](getting_started.md). This page is the
reference for routes, callbacks, browser events and sessions. The final section shows the
[core calls without Phoenix](#without-the-web-half).

## The routes

Import `Ithibati.Web.Router` in your router and mount the endpoints in a JSON pipeline:

```elixir
pipeline :ceremony do
  plug :accepts, ["json"]
  plug :fetch_session
  plug :protect_from_forgery
end

scope "/auth" do
  pipe_through :ceremony
  ithibati_routes handler: MyAppWeb.Auth, rp_name: "MyApp"
end
```

| Endpoint under this scope | Purpose |
| --- | --- |
| `POST /auth/registration/challenge` | Approve a registration subject and issue its challenge |
| `POST /auth/registration` | Verify the credential and call `register/4` |
| `POST /auth/authentication/challenge` | Issue a challenge without naming a credential |
| `POST /auth/authentication` | Verify the assertion and call `authenticate/2` |
| `POST /auth/recovery` | Redeem a code and call `recovered/3` |

The scope prefix is yours; the five suffixes are fixed. The pipeline must accept JSON, fetch
the session and apply CSRF protection. The hook supplies the `x-csrf-token` header from the
page's CSRF meta tag.

The hook sends `Accept: application/json`. A pipeline with `plug :accepts, ["html"]` rejects
that request with HTTP 406 before it reaches the ceremony controller. Check the pipeline on
the mounted scope if the browser reports this response.

Mount options are `handler:`, `rp_name:`, `user_verification:` and `seconds:`. User verification
defaults to `"preferred"`; challenge lifetime defaults to sixty seconds. Set
`user_verification: "required"` if your application requires authenticator user verification.

## The handler

Implement `Ithibati.Web.Handler` and name the module in `ithibati_routes/1`.

| Callback | Return on success | Application decision |
| --- | --- | --- |
| `registration_subject(conn, params)` | `{:ok, identifier_or_account}` | Who may start registration |
| `register(conn, key_attrs, subject, params)` | `{:ok, conn}` | How to store the verified credential |
| `authenticate(conn, account)` | `{:ok, conn}` | What a successful sign-in issues |
| `recovered(conn, account, fresh)` | `{:ok, conn}` | How to sign in and display any replacement codes |

All four callbacks may return `{:error, reason}`. Atom reasons become error-code strings in
JSON responses; other reasons are reported as `verification_failed`.

For a new account, `registration_subject/2` should validate and normalize the identifier with
your changeset before returning it. For another passkey on an existing account, return the
signed-in account itself; that lets Ithibati populate `excludeCredentials`. See
[Adding a passkey](passkeys.md#adding-a-passkey-through-phoenix).

`register/4` receives the subject approved at the challenge step. Use that subject when
building the account. The browser posts parameters again, so an identifier or invitation token
in the second request is not evidence of what was approved in the first.

Verification issues no session by itself. A typical handler creates one explicitly:

```elixir
@impl true
def authenticate(conn, account),
  do: {:ok, conn |> Gate.log_in(account) |> json(%{redirect: "/inside"})}
```

Here `Gate` aliases `Ithibati.Web.Gate` and `json/2` is imported from `Phoenix.Controller`.
Return a JSON `redirect` field for the hook to perform a full page load. A controller HTTP
redirect is not equivalent: the hook expects JSON. Other successful response bodies are sent
to the LiveView as `ithibati:done`.

`recovered/3` receives `nil` or a fresh recovery-code batch as its third argument. Do not drop
that batch; [Recovery codes](recovery.md#signing-in-with-one) shows the two branches.

## The JavaScript

Add an element with a stable ID and the endpoint URLs for the exchanges the page starts:

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

| LiveView event to push | Payload |
| --- | --- |
| `ithibati:register` | Registration parameters, such as `%{username: username}` or `%{token: token}` |
| `ithibati:authenticate` | `%{}` |
| `ithibati:recover` | `%{code: code}` |

The hook sends registration parameters with both requests. Authentication does not ask for an
identifier: the browser lets the person select a discoverable passkey.

Handle `ithibati:failed` for errors and `ithibati:done` for successful responses without a
redirect. The hook uses HTTP requests to let the controller update the session cookie.

### Browser imports

With the Hex dependency and Phoenix 1.8's generated esbuild setup, import the package in
`assets/js/app.js` and merge its hooks into the existing socket options:

```javascript
import {hooks as ithibatiHooks} from "ithibati"

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...ithibatiHooks},
})
```

Keep the generated `Socket`, `LiveSocket`, `csrfToken` and `colocatedHooks` definitions, and
any other hooks or options your application uses.

For a **local path dependency**, Mix does not create `deps/ithibati`. Add an esbuild alias that
points from the configured asset working directory to the library file. For sibling application
and library directories, with esbuild running from the application's `assets/`, this is:

```text
--alias:ithibati=../../ithibati/priv/static/ithibati.js
```

For the **colocated manifest**, set `ITHIBATI_COLOCATED_HOOKS=1` in the build environment and
recompile the dependency with `mix deps.compile ithibati --force`. Then use:

```javascript
import {hooks as ithibatiHooks} from "phoenix-colocated/ithibati"
```

The environment-variable change alone does not make Mix rebuild the dependency. Both imports
register the same hook name.

For browser code without LiveView, the package also exports `register` and `authenticate`.
They take WebAuthn options, call the browser credential API and return the credential data to
post to your server. They do not provide your application's HTTP transport.

## The relying party

The web layer derives the default relying-party ID and origin from your endpoint's configured
`:url`. Configure the public URL, including when a proxy terminates TLS:

```elixir
config :my_app, MyAppWeb.Endpoint,
  url: [host: "auth.example.com", scheme: "https", port: 443]
```

This produces `rp_id: "auth.example.com"` and origin `"https://auth.example.com"`.
The RP ID contains no scheme or port. For an ordinary browser deployment, use the page's
host or a registrable parent domain: `auth.example.com` can use `example.com`, but not `com`
or `www.example.com`. `www.` is a distinct subdomain, not an interchangeable spelling.
Cross-domain use requires the separate
[related-origin mechanism](https://www.w3.org/TR/webauthn-3/#sctn-related-origins), where supported;
adding an origin to the server's trusted list does not enable it in the browser.

Keep the relying-party ID stable: existing passkeys are bound to the ID used at registration.
A different ID requires enrolment for that ID; changing a redirect does not migrate credentials.

The optional `relying_party/2` handler callback receives the defaults. Use it to select values
for additional trusted clients, for example by adding an application-defined list of origins:

```elixir
def relying_party(_conn, {rp_id, origin}), do: {rp_id, [origin | @extension_origins]}
```

Choose origins from a fixed trusted set. Never reflect the request's `origin` header into this
return value: it lets the requester choose which origin the server trusts. This removes the
server's origin allowlist as a phishing defense, even though signature and RP-ID checks still
apply. For example, sharing an RP ID across subdomains does not make every subdomain trusted.
Support for an extension or native client also depends on that client's WebAuthn integration.

The core receives both values per call. Setting `config :wax_, origin: ...` or `rp_id: ...`
does not configure Ithibati.

## Who is signed in

`Ithibati.Web.Gate` reads the session and assigns `@current_account` on a connection or LiveView.

| Mode | Behaviour |
| --- | --- |
| `:current_account` | Assign the account or `nil`, then continue |
| `:require_account` | Refuse access when there is no account |

A plug in `:require_account` mode redirects when given `to:` and otherwise returns `401`.
A LiveView mount in that mode requires `to:`:

```elixir
live_session :members,
  on_mount: [{Ithibati.Web.Gate, {:require_account, to: "/"}}] do
  live "/inside", InsideLive
end
```

The gate authenticates sessions. Your application checks permissions and handles any bearer-token
authentication separately.

### Signing in and out

`Gate.log_in(conn, account)` renews the session and stores a new session token. It clears the
old session contents and CSRF token, so complete sign-in with a full page load.

`Gate.log_out(conn)` revokes that token and clears the session. With the endpoint's PubSub and
LiveView socket configured, it also disconnects sockets opened by that session. Keep the
generated socket's session connection information:

```elixir
socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [session: @session_options]]
```

The endpoint must have a `:pubsub_server`. Without those pieces, new requests lose access but
already-connected LiveViews are not disconnected by logout.

### Session storage and expiry

The gate uses these core calls:

```elixir
alias Ithibati.Identity.Sessions

Sessions.generate_session_token(account)
Sessions.get_user_by_session_token(token)
Sessions.delete_session_token(token)
```

Issuance returns the plaintext token; the row stores its SHA-256 digest. Lookup returns an
account or `nil` for a missing, unknown, revoked or expired token. Revocation returns `:ok`.
Sessions last sixty days by default; [Configuration](configuration.md#configuration) describes
`session_validity`.

There is no combined “sign out everywhere” function. Deleting the account's session rows
revokes them for future lookups:

```elixir
MyApp.Repo.delete_all(Ecto.assoc(account, :sessions))
```

This database operation does not broadcast socket disconnections. If your application needs
immediate disconnection across all sessions, implement that alongside the revocation.

## Handling failures

Controller failures return a JSON `error` string and a 4xx response. Browser failures use the
same vocabulary. The hook delivers both as `ithibati:failed`; your application supplies the
message shown to the person.

| Code | Meaning |
| --- | --- |
| `no_credentials` | No passkey is registered on this instance |
| `no_challenge` | No matching stored challenge is available |
| `malformed_credential` | The posted credential has an unexpected shape |
| `not_discoverable` | The credential was reported as not discoverable |
| `unknown_credential` | The credential is not stored on this instance |
| `no_attested_credential` | The attestation contains no credential to store |
| `credential_id_too_long` | The credential ID exceeds the storage limit |
| `already_enrolled` | The browser excluded this credential, or it already exists in storage |
| `invalid_code` | A recovery code is unknown or already spent |
| `verification_failed` | Verification or a handler returned a reason without a dedicated atom code |
| `ceremony_cancelled` | The browser reported `NotAllowedError`, including cancellation or timeout |
| `ceremony_failed` | Another browser or request failure prevented completion |
| `recovery_failed` | The recovery exchange did not complete successfully in the browser |
| `unknown` | The hook had neither an error code nor a status to report |

A failed network response does not prove the server did no work. In particular,
`recovery_failed` does not guarantee that the recovery code remains unused.

Two families carry a suffix: `http_<status>` for an unexpected HTTP response and
`missing_data_<attribute>` for a missing hook URL. Handle them by prefix or with a fallback.
Your handler can return additional atom codes.

`Ithibati.Ceremony.codes/0` lists the fixed codes and `Ithibati.Ceremony.families/0` lists the
families. Use them to check that your application's messages cover the library's vocabulary.

The event also carries `exception`, the browser's `DOMException` name or `nil`. Preserve it
for diagnosis. For example, `SecurityError` can point to a relying-party or origin mismatch.
`InvalidStateError` maps to `already_enrolled` during registration and `ceremony_failed` during
authentication.

## Without the web half

Call `Ithibati.Identity.Passkeys` directly when you provide the transport and challenge storage.
For registration on an existing account:

```elixir
alias Ithibati.Identity.Passkeys

challenge = Passkeys.registration_challenge(rp_id, origin, user_verification: "preferred")
options = Passkeys.registration_options(challenge, account, rp_name: "MyApp")
```

Send `options` to the client and retain the challenge and approved subject. When the credential
returns, consume the stored challenge and verify it:

```elixir
with {:ok, key_attrs} <- Passkeys.verify_registration(credential, challenge) do
  Passkeys.add_key(account, key_attrs)
end
```

For a new account, approve an identifier and pass it to `registration_options/3` instead of an
account. After verification, insert the account and append `Grant.with_key_and_codes/3` in a
single transaction, as shown in [Getting started](getting_started.md#5-the-handler).

For authentication, start with:

```elixir
case Passkeys.authentication_challenge(rp_id, origin) do
  {:ok, challenge} ->
    options = Passkeys.authentication_options(challenge)
    {challenge, options}

  {:error, :no_credentials} ->
    {:error, :no_credentials}
end
```

After the client responds, consume the stored challenge and call:

```elixir
Passkeys.verify_authentication(credential, challenge)
```

That returns `{:ok, account}` or `{:error, reason}`. Your integration must:

- Retain the challenge and approved subject between requests, and consume the challenge once,
  including after a failed verification. A signature on stored data alone does not prevent replay.
- Keep registration and authentication challenges separate and bind them to the intended flow.
- Supply a trusted relying-party ID and origin on every challenge call.
- Decide whether to issue a session or an application-owned credential after verification.

These fragments show the core calls; they are not a complete transport or challenge store.
