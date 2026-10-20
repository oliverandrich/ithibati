# Browser tests

A passkey ceremony runs in the browser. It needs `navigator.credentials`, a `fetch` that sets a
cookie and a redirect the hook follows. `Phoenix.LiveViewTest` has none of these.
Ithibati ships two helpers for browser tests with
[phoenix_test_playwright](https://hexdocs.pm/phoenix_test_playwright):

| Module | Does |
| --- | --- |
| `Ithibati.Testing.Passkeys` | Adds a virtual authenticator to the page, lists its credentials and deletes them |
| `Ithibati.Testing.Sessions` | Signs the browser in by session cookie, without a ceremony |

Both modules exist only when `phoenix_test_playwright` is a dependency.

## Set up

Add the dependency for tests:

```elixir
# mix.exs
{:phoenix_test_playwright, "~> 0.19.0", only: :test, runtime: false}
```

Pin `playwright` in `assets/package.json` and install it with its browser:

```console
$ npm install --prefix assets --save-dev --save-exact playwright
$ npm exec --prefix assets -- playwright install chromium --only-shell
```

Configure phoenix_test in `config/test.exs`, with the endpoint's `server: true`:

```elixir
config :phoenix_test, otp_app: :my_app, endpoint: MyAppWeb.Endpoint
```

Start Playwright in `test/test_helper.exs`:

```elixir
Application.put_env(:phoenix_test, :base_url, MyAppWeb.Endpoint.url())
{:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
```

## Use them

```elixir
defmodule MyAppWeb.RegistrationTest do
  use PhoenixTest.Playwright.Case

  import Ithibati.Testing.Passkeys

  test "a passkey is made", %{conn: conn} do
    virtual_authenticator(conn)

    conn
    |> visit("/")
    # Wait for the LiveView, or the click lands before its hook is bound.
    |> assert_has("[data-phx-main].phx-connected")
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

The virtual authenticator comes from Chrome's DevTools Protocol, so it needs Playwright's
Chromium. Firefox and WebKit have no equivalent.

Wait for the LiveView to connect before the first click, as the sample does. A page answers
before its socket joins, and a click before that goes nowhere.
