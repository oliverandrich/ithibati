# Getting started

This page walks an empty Phoenix application from `mix phx.new` to a working sign-in: somebody
registers with a passkey, writes down their recovery codes, lands on a page only accounts can
see, and signs out again. Take the same steps in your own project and the shape is the same.

You need Elixir 1.17 or newer and Postgres. Postgres is a requirement, not a default: the
migration reads your account table's catalogue entries to check what it is about to point a
foreign key at, and no other adapter answers those questions.

For the web half, Phoenix 1.8 and LiveView 1.1. Everything from step 7 on assumes them —
`Layouts.app`, the `<.input>` and `<.button>` components, the colocated-hooks import, and `deps`
being on esbuild's `NODE_PATH`, which is what makes the bare `"ithibati"` specifier resolve. The
context half needs neither.

```console
$ mix phx.new my_app
$ cd my_app
$ mix ecto.create
```

Both example applications in the repository do everything below, and CI drives them in a real
browser. If you would rather read finished code, start there. This page is the
open-registration one, spelled out.

## 1. Add the dependency

```elixir
def deps do
  [{:ithibati, "~> 0.1"}]
end
```

Phoenix, LiveView and Plug are optional dependencies, so a `phx.new` application already has
everything the web half needs. Leave them out and you get the context on its own; [Registering
and signing in](ceremonies.md#without-the-web-half) shows the ceremony as plain function calls.

## 2. Configure it

```elixir
config :ithibati,
  repo: MyApp.Repo,
  user_schema: MyApp.Accounts.User,
  users_key_type: :id
```

Put this in `config/config.exs`, above the `import_config` line at the bottom. That line has to
stay last. `users_key_type` and `table_prefix` are read at compile time, so neither can live in
`config/runtime.exs`.

`users_key_type` is the primary-key type of your users table, and Ithibati's foreign keys use it.
`:id` is what `mix phx.new` generates; write `:binary_id` if you asked for binary ids, which is
also Ithibati's own default. If the table disagrees with what you configured, the migration
refuses instead of building something that cannot be referenced. `users.id is bigint` against a
configured `:binary_id` is the message you get.

## 3. The account schema

You keep your own account schema and your own table. Two lines connect it to Ithibati, and both
generate code you will not see in the snippet below. `use Ithibati.Schema.User` records which
field identifies an account and adds `identifier_changeset/2`.
[`ithibati_account/0`](`Ithibati.Schema.User.ithibati_account/0`) declares that
field and the `passkeys`, `recovery_codes` and `sessions` associations.

```elixir
defmodule MyApp.Accounts.User do
  use Ecto.Schema

  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.User

  use User, identifier: :username, format: Identifier.username_format()

  import Ecto.Changeset

  schema "users" do
    ithibati_account()

    field :name, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> identifier_changeset(attrs)
    |> cast(attrs, [:name])
  end
end
```

### The identifier is yours to choose

There is no default, because a library that never sends mail has no business insisting on an
email address. Pass the field an account is known by, and a pattern if you want one:

```elixir
use User, identifier: :email, format: Identifier.email_format()
use User, identifier: :handle
```

This walkthrough uses a username, because that is what Ithibati can support end to end. It
cannot prove that somebody owns an email address, because it sends no mail. An application keyed
by an address is trusting whatever was typed in. That is a normal thing to do, and it is why
[`email_format/0`](`Ithibati.Schema.Identifier.email_format/0`) ships. It is not what a first
walkthrough should quietly assume.

`format:` is the regex the identifier has to match, and two come with the library. Leave the
option out and `identifier_changeset/2` still trims the value, downcases it and requires it. It
just does not check a shape.

A refused format reads "has invalid format", which is Ecto's wording and rarely yours. Pass
`format_message:` and it says what you wrote instead:

```elixir
use User, identifier: :email, format: Identifier.email_format(),
  format_message: "must be an email address we can reach you at"
```

It takes a module attribute like the others, and it needs a `format:`. There is nothing else here
for it to word.

[`username_format/0`](`Ithibati.Schema.Identifier.username_format/0`) is Mastodon's rule for a
*local* account: letters, digits and underscores, at
most thirty characters. Their looser pattern, the one that allows dots and hyphens, is for
addressing accounts on other servers rather than naming your own. It is strict on purpose: dots
and hyphens would let `alice.smith` register next to `alicesmith`, and characters outside ASCII
would let a Cyrillic а register next to a Latin a. Both pairs look identical on screen.

`email_format/0` is the pattern the HTML specification publishes for `<input type=email>`, not
RFC 5322. An identifier here is a credential, not a mailbox. The full grammar allows quoted
local parts with spaces in them, which is a hazard here. The pattern accepts `you@localhost` and
refuses `"a b"@example.com`.

Your own pattern is as welcome as either of them, written inline or named:

```elixir
@handle ~r/\A[a-z][a-z0-9_]{2,29}\z/

use User, identifier: :handle, format: @handle
```

Put the attribute above the `use` line, because that is where your module body reads it. An
attribute that does not exist yet, or one you misspelled, is `nil`, and Ithibati refuses
`format: nil` instead of quietly falling back to no pattern at all. `identifier:` is the one
option you cannot write as an attribute: it has to be a literal atom, because it names the field
your schema declares and belongs where you can read it.

`identifier_changeset/2` trims and downcases what it writes, so a plain unique index already
refuses `AdaLovelace` beside `adalovelace` and you do not need a functional index. A write that
bypasses the changeset stores whatever it is given.

> #### Should the identifier column be `citext`? {: .info}
>
> You do not need it. Lowercasing happens before anything reaches the database, so an ordinary
> unique index already does the job. `citext` is also an extension, and `CREATE EXTENSION
> citext` needs rights a hosted database does not always grant.
>
> They are also not the same thing, and the difference is what ends up stored. `citext` keeps
> what somebody typed and compares regardless of case; lowercasing keeps only the lowered
> value. So if you want `AdaLovelace` on a page, that is display: put it in a field of your own,
> or define `passkey_display_name/1` as shown below.
>
> Choose `citext` anyway when the reason is yours and not Ithibati's. Writes that bypass the
> changeset, say, or rows already in mixed case. Then pass `unique_index: false` and build the index yourself,
> which is what that option is for.

If a passkey dialog should show something friendlier than the identifier, define this:

```elixir
def passkey_display_name(account), do: account.name
```

You do not need a fallback. An account that has not filled it in returns `nil`, and Ithibati
shows the identifier instead.

## 4. The migration

A `phx.new` application has no `users` table. `priv/repo/migrations/` is empty, so you write
that one first. It is entirely yours; Ithibati only needs the identifier column to be in it:

```elixir
defmodule MyApp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string, null: false
      add :name, :string

      timestamps(type: :utc_datetime_usec)
    end
  end
end
```

`:name` is there because the schema in step 3 declares it; drop it if yours does not. The
timestamps match that schema, which uses `:utc_datetime_usec`. Ithibati's own tables do too.
Ecto raises if a schema and its table disagree about the type.

Then Ithibati's own migration, which you write and it fills in:

```elixir
defmodule MyApp.Repo.Migrations.AddIthibati do
  use Ecto.Migration

  def up, do: Ithibati.Migration.up(version: 1)
  def down, do: Ithibati.Migration.down(version: 1)
end
```

Pin the version, as above. An unpinned call creates a different set of tables depending on when
it runs, and rolls back neither. Run it after the migrations that create your own tables,
because it points foreign keys at your accounts table.

It creates `ithibati_keys`, `ithibati_recovery_codes`, `ithibati_sessions` and
`ithibati_bootstrap`, each with a foreign key to your account table. It also creates the unique
index on your identifier column, because a changeset cannot keep an identifier unique against a
concurrent insert. Only the database can.

Deleting an account takes its passkeys, its recovery codes and its sessions with it. That is
`on_delete: :delete_all`, so your own delete path needs no cleanup here. The bootstrap row is
the exception. Its `user_id` is nilified and the row stays, because what it records is
that this instance *was* set up, and that stays true after the account that did it is gone.

That row is a singleton behind a unique index. If your application has a singleton of its own,
[Invitations, and the first account](invitations.md) says why the order you write to them in
matters.

The identifier column itself is yours. Add it in the `create table` that builds your users table,
or in an `alter` if that table already exists:

```elixir
alter table(:users) do
  add :username, :string, null: false
end
```

> #### Why does Ithibati index this column but not create it? {: .info}
>
> Because a rollback can take an index back and cannot take a column back.
> [`down/1`](`Ithibati.Migration.down/1`) drops the
> index and your rows are untouched; dropping the column would take the identity of every
> account with it, in a table that is yours. So Ithibati never creates one, and never has to
> decide whether to drop it.
>
> Two smaller reasons sit on top. It could not guess the type, since `citext` is a normal
> choice here. And `null: false` cannot be added to a table that already has rows without a
> default or a backfill, so the column it made would be missing the one constraint you wanted.
>
> The index is worth the asymmetry because nothing else can keep the identifier unique: two
> registrations at the same moment both pass the changeset and both insert. A forgotten index is
> not a migration that fails, it is the day two accounts answer to one name.

Forget the column and the migration says so before it builds anything:

```
** (ArgumentError) MyApp.Accounts.User declares users.username, and the table has no such
column. The column is yours to add — in the migration that creates the table, or in one of its
own — and this library creates the unique index on it.
```

Before it builds anything, the migration checks `users_key_type` against your accounts table: the
column its foreign keys point at has to exist, have the type you configured, and carry a unique
index. That last one is what Postgres requires of any referenced column, so a composite primary
key with a unique index beside it is fine. A disagreement is refused, not half-applied.

Then `mix ecto.migrate`.

### Saying how the identifier index is built

Ithibati builds that index while the migration runs, but you steer it from the `use` line in your
schema rather than from the migration. Two options do it, and both may be module attributes, like
`format:`.

Ecto derives the index name from the table and the column. If that is not your convention, name
it yourself and Ithibati creates it under that name:

```elixir
use User, identifier: :username, constraint_name: :users_username_uniq
```

You may want to build the index yourself. A partial index, an expression, `citext`, a composite
with a tenant column. Say so, and Ithibati stops creating one. It then checks that a
unique index covering that column exists and refuses the migration if it does not:

```elixir
use User, identifier: :username, unique_index: false
```

### A later release that adds tables

The schema is versioned, and `version: 1` is what this release builds. When a later release of
Ithibati adds to it, the changelog says so and names the new number;
`Ithibati.Migration.current_version/0` answers with the one your installed copy knows. Until that
happens there is nothing to do. The migration you already wrote stays pinned at 1 and does not
run again.

Upgrading is a second migration of your own, saying where it starts:

```elixir
def up, do: Ithibati.Migration.up(from: 1, version: 2)
def down, do: Ithibati.Migration.down(from: 1, version: 2)
```

You never write the SQL by hand, and Ecto records what has been applied in your own
`schema_migrations`.

## 5. The handler

This is the module Ithibati asks whenever it reaches a decision it does not make: who may
register, what an account is made of, what a successful ceremony issues, and what happens when
somebody signs in with a recovery code instead. Four callbacks, and `Ithibati.Web.Handler`
documents each one.

It lives under `MyAppWeb`, not in the context, because every callback takes a `conn` and
hands one back. It sets the session and answers the request. It is the same place
`phx.gen.auth` puts `MyAppWeb.UserAuth`. What it does *with* the account, once a credential has
verified, is context work and can move into one of yours; this walkthrough keeps it inline so
the whole flow is on one page.

```elixir
defmodule MyAppWeb.Auth do
  @behaviour Ithibati.Web.Handler

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_session: 3]

  alias Ecto.Multi
  alias Ithibati.Identity.Grant
  alias Ithibati.Web.Gate
  alias MyApp.Accounts.User
  alias MyApp.Repo

  @impl true
  def registration_subject(_conn, %{"username" => username}) do
    %User{}
    |> User.changeset(%{"username" => username})
    |> Ecto.Changeset.apply_action(:insert)
    |> case do
      {:ok, account} -> {:ok, account.username}
      {:error, _changeset} -> {:error, :invalid_username}
    end
  end

  def registration_subject(_conn, _params), do: {:error, :username_required}

  @impl true
  def register(conn, key_attrs, username, _params) do
    Multi.new()
    |> Multi.insert(:account, User.changeset(%User{}, %{"username" => username}))
    |> Grant.with_key_and_codes(key_attrs)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account, recovery_codes: codes}} ->
        {:ok,
         conn
         |> Gate.log_in(account)
         |> put_session(:recovery_codes, codes)
         |> json(%{redirect: "/recovery-codes"})}

      {:error, :account, %Ecto.Changeset{} = changeset, _changes} ->
        if Ithibati.Schema.User.identifier_taken?(changeset),
          do: {:error, :username_taken},
          else: {:error, :invalid_username}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @impl true
  def authenticate(conn, account),
    do: {:ok, conn |> Gate.log_in(account) |> json(%{redirect: "/"})}

  @impl true
  def recovered(conn, account, nil), do: authenticate(conn, account)

  def recovered(conn, account, fresh) do
    {:ok,
     conn
     |> Gate.log_in(account)
     |> put_session(:recovery_codes, fresh)
     |> json(%{redirect: "/recovery-codes"})}
  end
end
```

[`recovered/3`](`c:Ithibati.Web.Handler.recovered/3`) is the one for somebody signing in with a recovery code instead of a passkey. Its two clauses are the whole of it: no fresh batch, sign them in as usual; a fresh
batch, show it once on the page step 6 builds. That third argument is a fresh batch only when
the code just spent was their last. It is a separate callback, not a flag on
[`authenticate/2`](`c:Ithibati.Web.Handler.authenticate/2`) because that
batch is the only copy there will ever be, and a signature with nowhere to put it is a signature
that loses it.

Three more things in there are worth pausing on.

[`registration_subject/2`](`c:Ithibati.Web.Handler.registration_subject/2`) may answer with the
identifier or with the account itself. Here it is the identifier, because the account does not
exist yet. Hand back an account when there is one
(enrolling a second device), and
[`registration_options/3`](`Ithibati.Identity.Passkeys.registration_options/3`) can then list its
existing credentials
in `excludeCredentials`, so a browser does not offer an authenticator that is already enrolled.

It is asked **before** a challenge is minted, which is why an identifier your schema could never
store is refused there. Approving it would mean a passkey dialog, a
credential the authenticator then keeps, and a refusal only after all of that. It asks the
changeset instead of repeating the pattern, and answers with the normalised value, so the name
on the dialog is the name that gets stored.

[`register/4`](`c:Ithibati.Web.Handler.register/4`) composes.
[`Grant.with_key_and_codes/3`](`Ithibati.Identity.Grant.with_key_and_codes/3`) appends the passkey
and the recovery codes
to the transaction that creates the account, so an account never exists without a way back in.
Your own steps go into the same `Multi` and commit or roll back with it. A membership row, a
default project, whatever the account needs.

It reads the account from the step that made it, expecting one called `:account`; pass
`account: :person` if yours is named something else. It adds two steps of its own, `:passkey` and
`:recovery_codes`, so do not use those names. The second is the one you destructure to show the
codes.

Its error branch asks `Ithibati.Schema.User.identifier_taken?/1`, because a name somebody else
already has and a name that is not allowed both arrive as `{:error, changeset}` and need
different words on screen. Written by hand, that check is a scan for `constraint: :unique`, which
also matches your own unique columns, a slug or a tenant key, and reports a collision on one of
those as the address being taken. Ithibati named the identifier field, so it knows which error
belongs to it. Ask after the insert: a constraint error only exists once the database has refused
a write.

Both `register/4` and `authenticate/2` answer with a redirect. Signing in renews the session and
clears the CSRF token with it, so the flow has to end in a full page load, and the hook follows
that redirect.

## 6. Showing the recovery codes

The handler put the codes in the session and redirected to `/recovery-codes`. That page is the
only time anybody will see them: the rows hold sha256 digests, and nothing recovers the plaintext
afterwards.

> #### Why a controller and not a LiveView? {: .info}
>
> The session key has to be gone once the page has been read, and a LiveView has no connection to
> delete it from. A refresh would show the codes again, which is the opposite of showing them
> once.

```elixir
defmodule MyAppWeb.SessionController do
  use MyAppWeb, :controller

  alias Ithibati.Web.Gate

  def recovery_codes(conn, _params) do
    case get_session(conn, :recovery_codes) do
      nil -> redirect(conn, to: "/")
      codes -> conn |> delete_session(:recovery_codes) |> render(:recovery_codes, codes: codes)
    end
  end

  def sign_out(conn, _params), do: conn |> Gate.log_out() |> redirect(to: "/")
end
```

```heex
<Layouts.app flash={%{}}>
  <.header>
    Your recovery codes
    <:subtitle>
      Twelve, each good for one sign-in, and this is the only time they are shown.
    </:subtitle>
  </.header>

  <div class="alert alert-warning mt-6">
    <span>The database holds only their digests. Put these somewhere safe now.</span>
  </div>

  <ul class="mt-6 grid grid-cols-2 gap-2 font-mono text-sm">
    <li :for={code <- @codes} class="rounded bg-base-200 px-3 py-2">{code}</li>
  </ul>

  <p class="mt-6"><.link navigate={~p"/"} class="link">Done</.link></p>
</Layouts.app>
```

`render/3` needs a view module, which `phx.new` did not generate for this controller. Put it in
`lib/my_app_web/controllers/session_html.ex`:

```elixir
defmodule MyAppWeb.SessionHTML do
  use MyAppWeb, :html

  embed_templates "session_html/*"
end
```

The template belongs at `lib/my_app_web/controllers/session_html/recovery_codes.html.heex`.
Leaving the module out compiles cleanly and passes `mix ithibati.doctor`. It only fails at the
first successful registration, when somebody has already created a passkey and their codes have
already been issued.

Twelve codes by default, each good for one sign-in. Spending the last one issues a fresh batch in
the same transaction, because an account with no passkey and no codes left is locked out for
good. [Recovery codes](recovery.md) covers redeeming one, `count:`, and how to turn the refill
off.

## 7. The routes

Four pieces go into the router `phx.new` generated: the import, the gate in `:browser`, a second
pipeline, and the scopes. Everything the generator put there stays: `get "/", PageController`,
and the `dev_routes` block with LiveDashboard and the mailbox preview in it. Shown whole so the
order is visible:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  import Ithibati.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug Ithibati.Web.Gate, :current_account
  end

  pipeline :ceremony do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
  end

  scope "/auth" do
    pipe_through :ceremony
    ithibati_routes handler: MyAppWeb.Auth, rp_name: "MyApp"
  end

  scope "/", MyAppWeb do
    pipe_through :browser

    live_session :public, on_mount: [{Ithibati.Web.Gate, :current_account}] do
      live "/", SignInLive
    end

    live_session :members, on_mount: [{Ithibati.Web.Gate, {:require_account, to: "/"}}] do
      live "/inside", InsideLive
    end

    get "/recovery-codes", SessionController, :recovery_codes
    delete "/session", SessionController, :sign_out
  end
end
```

> #### Why a second pipeline instead of `:browser`? {: .info}
>
> These endpoints answer JSON, and `:browser`'s `accepts ["html"]` refuses the hook's
> request with a 406 before the controller is ever reached. The other two plugs are load-bearing
> as well: the challenge waits in the session between the two round-trips, and the hook answers
> `protect_from_forgery` with an `x-csrf-token` header, which a JSON body is not exempt from.
> [The routes](ceremonies.md#the-routes) has the detail.

`Ithibati.Web.Gate` answers who is signed in, in a pipeline and in a `live_session`, from one
module. `:current_account` assigns `@current_account` or `nil` and always continues.
`:require_account` refuses when there is nobody, and needs `:to` in a `live_session`, because a
LiveView that halts with nowhere to send a person is a dead end.

Signing out is a plain `delete`, for the same reason the recovery codes are a controller: a
LiveView cannot clear a session cookie.

## 8. The browser

The ceremonies need client code, because the browser's API wants buffers where Ithibati sends
unpadded base64url, and it hands back a credential that has to be serialised the way the
verifications expect. Ithibati ships it, and the specifier is bare because a Phoenix 1.8
application already has `deps` on esbuild's `NODE_PATH`, where a Hex dependency lives.

That last part is why a **path** dependency needs one more argument: Mix creates no
`deps/ithibati` for one, so there is nothing on `NODE_PATH` to resolve the name against and
esbuild stops with `Could not resolve "ithibati"`. Point it at the file instead, as another
`--alias` in the esbuild arguments `phx.new` generated in `config/config.exs`:

```elixir
config :esbuild,
  version: "0.28.2",
  my_app: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js
         --external:/fonts/* --external:/images/* --alias:@=.
         --alias:ithibati=../../ithibati/priv/static/ithibati.js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]
```

The alias path is resolved from `cd:`, which is your `assets/` directory. So it is your path to
the library with `assets/` climbed out of first. Both example applications carry exactly this
line, and say why in a comment beside it. Taking Ithibati from Hex needs none of it.

In `assets/js/app.js`:

```javascript
import {hooks as ithibatiHooks} from "ithibati"

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...ithibatiHooks},
})
```

## 9. The page people register and sign in on

One page, two ceremonies. Registering is a form, because it needs a name. Signing in is a
button.

> #### Where is the login form? {: .info}
>
> There is not one, and this is the part that surprises people coming from passwords.
>
> A sign-in challenge names no credential. `allowCredentials` is sent empty, so the browser
> offers whichever passkeys it holds for your site and the person picks one. There is nothing to
> type, so there is nothing to submit. A button is the whole interface, and it works on a device
> where nobody has ever typed their username.
>
> Registering is the other way round: the name does not exist yet, so you have to ask for it,
> and `registration_subject/2` is where your application approves it.

The LiveView says *when* a ceremony starts; the hook does the round-trips. A ceremony ends in a
session cookie and a LiveView cannot set one, so the hook posts to the endpoints over `fetch` and
follows the redirect your handler answered with.

`phx.new` generates no `live/` directory, so `mkdir lib/my_app_web/live` first.

```elixir
defmodule MyAppWeb.SignInLive do
  use MyAppWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, username: "", error: nil)}

  @impl true
  def handle_event("validate", %{"username" => username}, socket),
    do: {:noreply, assign(socket, username: username, error: nil)}

  def handle_event("register", %{"username" => username}, socket),
    do:
      {:noreply,
       socket |> assign(error: nil) |> push_event("ithibati:register", %{username: username})}

  def handle_event("sign-in", _params, socket),
    do: {:noreply, socket |> assign(error: nil) |> push_event("ithibati:authenticate", %{})}

  def handle_event("recover", %{"code" => code}, socket),
    do: {:noreply, socket |> assign(error: nil) |> push_event("ithibati:recover", %{code: code})}

  # A successful ceremony ends in the redirect the handler answered with, so only failures arrive
  # back here.
  def handle_event("ithibati:failed", %{"error" => error}, socket),
    do: {:noreply, assign(socket, error: message(error))}

  def handle_event("ithibati:done", _payload, socket), do: {:noreply, socket}

  defp message("username_taken"), do: "That username is taken."
  defp message("invalid_username"),
    do: "A username is letters, digits and underscores, up to thirty characters."
  defp message("username_required"), do: "Pick a username to register."
  defp message("no_credentials"), do: "No passkey is registered here yet."
  defp message("invalid_code"), do: "That recovery code is not one we can use."
  defp message("ceremony_cancelled"), do: "The passkey prompt was dismissed."
  defp message("already_enrolled"), do: "That device already holds a passkey for this site."
  defp message(other), do: "Something went wrong: #{other}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div :if={@error} class="alert alert-error"><span>{@error}</span></div>

      <form phx-change="validate" phx-submit="register">
        <.input name="username" value={@username} label="Username" required placeholder="ada_lovelace" />
        <.button variant="primary">Register</.button>
      </form>

      <.button phx-click="sign-in" class="btn mt-4">Sign in with a passkey</.button>

      <form phx-submit="recover" class="mt-8">
        <.input name="code" value="" label="Lost your passkey? Use a recovery code" required />
        <.button class="btn">Sign in with a code</.button>
      </form>

      <div
        id="passkey"
        phx-hook="Ithibati.Web.Hooks.PasskeyCeremony"
        data-registration-challenge-url={~p"/auth/registration/challenge"}
        data-registration-url={~p"/auth/registration"}
        data-authentication-challenge-url={~p"/auth/authentication/challenge"}
        data-authentication-url={~p"/auth/authentication"}
        data-recovery-url={~p"/auth/recovery"}
      >
      </div>
    </Layouts.app>
    """
  end
end
```

> #### Why does the registration form look like that? {: .info}
>
> It lives in a LiveView of yours, and here in the same one as the sign-in button, because one
> page is shorter to walk through. Two separate routes work exactly as well: `/register` and
> `/sign-in`, each with its own copy of the hook element below, and nothing else shared.
>
> What is unusual is that there is no `to_form/2` and no changeset, because `phx-submit` does
> not send this form anywhere. It hands the value to the hook, which posts it to
> `/auth/registration/challenge` and starts the ceremony; the form is never submitted in the
> Phoenix sense. Validation still happens on the server, one step later:
> `registration_subject/2` is asked before a challenge is minted, and its refusal is what the
> person sees.
>
> `phx-change="validate"` is there so you can check the field while it is typed, before anybody
> is shown a passkey dialog. This walkthrough only keeps the value; a changeset behind it works
> the same way.

The empty `<div id="passkey">` is the hook. It renders nothing, drives all three exchanges, and
reads
the endpoint paths off its own attributes, because you chose the scope they are mounted under.
Set the pair for each ceremony that page starts; a missing one is reported as
`missing_data_registration_url`, not as a ceremony that failed.

And the page behind the gate, an ordinary LiveView that can now count on `@current_account`:

```elixir
defmodule MyAppWeb.InsideLive do
  use MyAppWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <p>
        Signed in as <strong>{@current_account.username}</strong>
        — <.link href={~p"/session"} method="delete" class="link">sign out</.link>.
      </p>
    </Layouts.app>
    """
  end
end
```

## 10. Check it, then run it

```console
$ mix ithibati.doctor
```

Thirteen checks in one run, so you find out now and not at the first sign-in. Then `mix
phx.server`, open `http://localhost:4000` and register: the browser asks for a passkey, you
create one, and you land on the recovery codes. Write one down. Sign out, sign back in with the
passkey, sign out again and use that code instead. Both ways in work. The loop is closed.

[`mix ithibati.doctor`](doctor.md) has the rest of what it asks.

## Configuration

The three keys in step 2 are the ones every application sets. Everything else has a default, and
you set it only when the default does not fit:

```elixir
config :ithibati,
  user_schema: MyApp.Accounts.User,   # required — the module that uses Ithibati.Schema.User
  repo: MyApp.Repo,                   # required — the repo this library reads and writes through
  session_validity: {30, :day},       # default {60, :day} — how long a sign-in lasts
  invitation_schema: MyApp.Accounts.Invitation,  # optional — only if you use invitations
  users_key_type: :id,                # default :binary_id — compiled into the schemas
  table_prefix: "auth"                # default "ithibati" — compiled into the schemas
```

`session_validity` is how long a sign-in lasts. The units are `:second`, `:minute`, `:hour`,
`:day` and `:week`; `:month` and `:year` are missing because neither has a fixed length. A value
this library cannot read is refused, never guessed at.

`users_key_type` and `table_prefix` are read at compile time, so changing either recompiles
Ithibati. Elixir then refuses to boot against a value it was not built for, instead of looking
for a table nobody meant.

## Where to go next

- [Registering and signing in](ceremonies.md) — the handler and the hook in full, the relying
  party, and the ceremony without Phoenix.
- [Recovery codes](recovery.md) — redeeming one, and what happens when the last is spent.
- [Passkeys](passkeys.md) — enrolling a second device, and the one you cannot delete.
- [Invitations, and the first account](invitations.md) — the same application again, with
  registration closed to strangers. It picks up where this page leaves off.
- [Ithibati](overview.md) — the map of every page, and the design decisions behind them.
