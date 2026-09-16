# Ithibati

![Ithibati](assets/logo.png)

Passkey authentication for Elixir applications: accounts, WebAuthn credentials, recovery codes
and revocable sessions. It has no opinion about what an account may do. The web half is optional
and built for Phoenix.

[Swahili, *ithibati*](https://en.wiktionary.org/wiki/ithibati): proof, evidence. In WebAuthn's own vocabulary, attestation.

## What it is

Most authentication libraries answer two questions at once. *Who is this*, and *what may they
do*.

The second answer is different in every application. Sites, tenants, teams, roles, invitations.
That is why the first one so rarely gets reused. Ithibati answers only the first:

- passkey registration and authentication (WebAuthn, via [`wax_`](https://hex.pm/packages/wax_)),
  including the first account on an empty instance
- single-use recovery codes, for the day a passkey is gone
- revocable server-side sessions. The cookie carries a secret and the database carries its
  digest. Signing out revokes the row instead of forgetting it
- invitations: Ithibati brings the token, its expiry and the redemption, you bring the table and
  whatever the invitation grants
- changeset helpers and composable `Ecto.Multi` fragments you hang your own steps on

You keep your own `users` table and your own roles, and Ithibati never reads them. Creating an
account, its first passkey and its recovery codes is one transaction, and you add your own steps
to it.

An account is identified by a username or an email address, whichever your application uses.
Two patterns ship, `Identifier.username_format/0` and `Identifier.email_format/0`. You can pass
your own. You declare the field on your own schema.

Open registration and invitation-only both work. Ithibati does not push you either way.

It sends no mail, so delivering an invitation link is your job. An invitation token is a bearer
secret, and whoever has the link accepts it. That also answers address verification. An
application that mails the link itself has proved the address, because Ithibati refuses an
account created under any identifier but the one the invitation was addressed to.

## What using it looks like

There are five touchpoints, and they are the whole surface. [Getting
started](https://hexdocs.pm/ithibati/getting_started.html) builds them into a working
application, step by step, from `mix phx.new` onwards.

The dependency:

```elixir
{:ithibati, "~> 0.1"}
```

One line in your account schema names the field an account is known by, and brings the changeset
that validates it:

```elixir
use User, identifier: :username, format: Identifier.username_format()
```

One line in your router mounts the ceremony endpoints:

```elixir
ithibati_routes handler: MyAppWeb.Auth, rp_name: "MyApp"
```

Your handler decides what a verified assertion is worth. Ithibati hands you the account and
issues nothing:

```elixir
@impl true
def authenticate(conn, account),
  do: {:ok, conn |> Gate.log_in(account) |> json(%{redirect: "/"})}
```

And a page starts a ceremony by pushing an event to the browser hook:

```elixir
def handle_event("sign-in", _params, socket),
  do: {:noreply, socket |> assign(error: nil) |> push_event("ithibati:authenticate", %{})}
```

There is no password field. There is also no sign-in form. A sign-in challenge names no
credential, so the browser offers whichever passkeys it holds for your site and the person picks
one. Registration still needs a form, because the name does not exist yet.

Configuration, the migration and the account schema in full are in the guide. `mix
ithibati.doctor` checks the lot when you are done.

## Without Phoenix

Phoenix, LiveView and Plug are optional dependencies. The web half comes with them: the ceremony
routes, a gate that answers who is signed in, and a browser hook. Most applications want that,
and both examples are built that way.

You can skip it. A ceremony is a handful of function calls. The controller only adds HTTP and
somewhere to park the challenge between two requests. The browser side works without a framework
too. `priv/static/ithibati.js` exports `register` and `authenticate` as plain functions, and the
LiveView hook wraps them. Use this for a native client, a browser extension, or a server that is
not Phoenix. [Registering and signing in](https://hexdocs.pm/ithibati/ceremonies.html) shows both
ways.

## Where to go next

The [documentation](https://hexdocs.pm/ithibati) covers it properly. [Getting
started](https://hexdocs.pm/ithibati/getting_started.html), [registering and signing
in](https://hexdocs.pm/ithibati/ceremonies.html), [recovery
codes](https://hexdocs.pm/ithibati/recovery.html),
[passkeys](https://hexdocs.pm/ithibati/passkeys.html), [invitations and the first
account](https://hexdocs.pm/ithibati/invitations.html) and the
[tooling](https://hexdocs.pm/ithibati/doctor.html).

Two example applications compile and run, one for each way of letting people in. Read these when
the docs and your editor disagree:

- [`examples/open_registration`](https://github.com/oliverandrich/ithibati/tree/main/examples/open_registration)
  — anybody who reaches the page picks a username and registers a passkey.
- [`examples/invitation_only`](https://github.com/oliverandrich/ithibati/tree/main/examples/invitation_only)
  — the first account claims the instance. Everybody after it needs an invitation link.

CI compiles both, runs their tests and drives them in a browser, so they cannot quietly rot.

[CHANGELOG.md](CHANGELOG.md) has what changed between releases.

## Licence

MIT. See [LICENSE](LICENSE).
