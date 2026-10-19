if Code.ensure_loaded?(PhoenixTest.Playwright) do
  defmodule Ithibati.Testing.Sessions do
    @moduledoc """
    Signs a browser in for tests with `PhoenixTest.Playwright`, without a passkey ceremony.

    A ceremony takes about as long as the rest of a typical browser test. Tests whose subject comes
    after signing in can start from a session cookie instead. The page and its socket then load the
    account as after a real sign-in.

        test "the library opens", %{conn: conn} do
          account = Repo.insert!(%User{username: "ada"})
          conn |> sign_in(account, MyAppWeb.Endpoint.session_options()) |> visit("/")
        end

    The module exists only when `phoenix_test_playwright` is a dependency.
    """

    alias Ithibati.Identity.Sessions
    alias Ithibati.Web.Gate

    @doc """
    Stores a new session for `account` and sets it as the browser's session cookie.

    `session_options` are the options the endpoint passes to `Plug.Session`. They name the cookie
    and carry its signing and encryption salts. Returns `conn`.

    The cookie also names the session's LiveView socket, as `Ithibati.Web.Gate.log_in/2` does.
    Revoking the session then disconnects the browser's LiveViews. The endpoint needs PubSub.
    """
    def sign_in(conn, account, session_options) do
      token = Sessions.generate_session_token(account)
      session = %{Gate.session_key() => token, "live_socket_id" => Gate.live_socket_id(token)}

      PhoenixTest.Playwright.add_session_cookie(conn, [value: session], session_options)
    end
  end
end
