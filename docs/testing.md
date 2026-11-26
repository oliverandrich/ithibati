# Browser tests

A passkey ceremony runs in the browser. It needs `navigator.credentials`, a `fetch` that sets a
cookie and a redirect the hook follows. `Phoenix.LiveViewTest` has none of these.
Ithibati ships two helpers for browser tests with [Fluffy](https://hexdocs.pm/fluffy):

| Module | Does |
| --- | --- |
| `Ithibati.Testing.Passkeys` | Adds a virtual authenticator to the browser, lists its credentials and deletes them |
| `Ithibati.Testing.Sessions` | Signs the browser in by session cookie, without a ceremony |

Both modules exist only when `fluffy` is a dependency. They take the `Fluffy.PhoenixTest`
session as `conn`.

## Set up

Add the dependency for tests:

```elixir
# mix.exs
{:fluffy, "~> 0.9.0-rc.7", only: :test}
```

Install Playwright's driver and its browser:

```console
$ MIX_ENV=test mix playwright.install chromium --only-shell
```

Configure Fluffy in `config/test.exs`, with the endpoint's `server: true`:

```elixir
config :fluffy, endpoint: MyAppWeb.Endpoint
```

## Use them

```elixir
defmodule MyAppWeb.RegistrationTest do
  use MyAppWeb.ConnCase
  use Playwright.Test

  import Fluffy.PhoenixTest
  import Ithibati.Testing.Passkeys

  setup do
    %{conn: start_session(:playwright)}
  end

  test "a passkey is made", %{conn: conn} do
    virtual_authenticator(conn)

    conn
    |> visit("/")
    |> fill_in("Username", with: "ada")
    |> click_button("Register")
    |> assert_path("/recovery-codes")

    assert length(credentials(conn)) == 1
  end
end
```

`forget_credentials/1` deletes the passkeys the authenticator holds. A later sign-in then runs
like one on a device that never registered a passkey:

```elixir
conn
|> forget_credentials()
|> click_button("Sign in with a passkey")
|> assert_has(".alert-error")
```

`Ithibati.Testing.Sessions.sign_in/3` takes the account and the options the endpoint passes to
`Plug.Session`. Use it for features whose subject comes after signing in. Endpoints usually keep
these options in a module attribute, so expose them for the tests:

```elixir
# lib/my_app_web/endpoint.ex
def session_options, do: @session_options
```

## Limits

The virtual authenticator is Playwright's, so it works in Chromium, Firefox and WebKit. It
replaces `navigator.credentials` with a script that reports no extension results and does not
check the relying party id against the origin.
