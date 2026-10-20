defmodule IthibatiOpenWeb.RegistrationTest do
  @moduledoc """
  The ceremonies, in a browser, through the JavaScript this library ships.

  A green run here says the shipped client code works — not that a copy of it does: the example
  bundles `priv/static/ithibati.js` with esbuild, and that bundle is what the page loads.
  """
  use IthibatiOpenWeb.PlaywrightCase

  test "a passkey is made, the codes are shown once, and the same passkey signs back in", %{
    conn: conn
  } do
    virtual_authenticator(conn)

    conn
    |> open("/")
    |> fill_in("Username", with: "ada")
    |> click_button("Register")
    # The handler answers `%{redirect: "/recovery-codes"}` and the hook acts on it with a full page
    # load, which a sign-in needs anyway: renewing the session takes the CSRF token with it.
    |> assert_path("/recovery-codes")
    |> assert_has("h1", text: "Your recovery codes")
    |> assert_has("main li", count: 12)

    # The rows, not only the page: this is what `malformed_credential` would have prevented, and
    # reading it in the same sandboxed connection the browser wrote through is what a browser
    # driven from outside the application cannot do.
    assert account = Repo.get_by(User, username: "ada")
    assert Repo.aggregate(Ecto.assoc(account, :passkeys), :count) == 1
    assert Repo.aggregate(Ecto.assoc(account, :recovery_codes), :count) == 12

    # And the authenticator kept what the *page* registered, which is how we know the ceremony
    # reached `navigator.credentials.create` rather than being simulated around it.
    assert length(credentials(conn)) == 1

    conn
    |> open("/inside")
    |> assert_has("p", text: "Only ada sees this.")
    |> open("/")
    |> sign_out("/session")
    |> refute_has(".alert-success")

    # Usernameless: the sign-in names no credential at all, so this only works because the
    # credential is discoverable — the property `registration_options/3` refuses to leave to the
    # authenticator's discretion.
    # This redirect leads back to `/`, where the browser already is.
    conn
    |> click_button("Sign in with a passkey")
    |> assert_has(".alert-success", text: "Signed in as ada")
  end

  # The shortcut a feature takes when signing in is not its subject.
  test "a session cookie signs the browser in without a ceremony", %{conn: conn} do
    account = Repo.insert!(User.changeset(%User{}, %{username: "ada"}))

    conn
    |> Ithibati.Testing.Sessions.sign_in(account, IthibatiOpenWeb.Endpoint.session_options())
    |> open("/inside")
    |> assert_has("p", text: "Only ada sees this.")
  end

  # The cookie names the session's socket topic, as a real sign-in does, so revoking reaches it.
  test "a LiveView signed in by cookie disconnects when its session is revoked", %{conn: conn} do
    account = Repo.insert!(User.changeset(%User{}, %{username: "ada"}))

    conn
    |> Ithibati.Testing.Sessions.sign_in(account, IthibatiOpenWeb.Endpoint.session_options())
    |> open("/inside")
    |> assert_has("p", text: "Only ada sees this.")

    digests = Ithibati.Identity.Sessions.revoke_all(account)
    :ok = Ithibati.Web.Gate.disconnect_sessions(IthibatiOpenWeb.Endpoint, digests)

    refute_has(conn, "p", text: "Only ada sees this.")
  end

  # An emptied authenticator models a device that never held the passkey.
  test "an authenticator without the passkey cannot sign in", %{conn: conn} do
    virtual_authenticator(conn)
    register(conn, "ada")

    conn
    |> open("/")
    |> sign_out("/session")
    |> forget_credentials()
    |> click_button("Sign in with a passkey")
    |> assert_has(".alert-error")
    |> refute_has(".alert-success", text: "Signed in as ada")
  end

  # The day the passkey is gone. Everything else here needs an authenticator; this is the one
  # path that must work without one, and it is the reason the codes exist at all.
  test "a recovery code signs somebody in when the passkey cannot", %{conn: conn} do
    virtual_authenticator(conn)

    [code | _rest] = conn |> register("grace") |> recovery_codes()

    conn
    |> open("/")
    |> sign_out("/session")
    |> fill_in("Lost your passkey? Use a recovery code", with: code)
    |> click_button("Sign in with a code")
    |> assert_has(".alert-success", text: "Signed in as grace")

    # Spent, not merely unmatched: the row is what makes a second use refusable.
    account = Repo.get_by(User, username: "grace")
    assert Ithibati.Identity.RecoveryCodes.remaining(account) == 11

    conn
    |> open("/")
    |> sign_out("/session")
    |> fill_in("Lost your passkey? Use a recovery code", with: code)
    |> click_button("Sign in with a code")
    |> assert_has(".alert-error", text: "recovery code")
  end

  # The bug `Ithibati.Web.Gate` closes: a revoked token stops the *next* request and the next
  # mount, while a LiveView already connected holds its account in assigns and goes on accepting
  # events as that account until something tells its socket to go away.
  test "signing out in one tab ends a LiveView left open in another", %{conn: conn} do
    virtual_authenticator(conn)
    register(conn, "ada")

    # A second tab of the same browser, so the same cookie.
    other = conn |> second_tab("/inside") |> assert_has("p", text: "Only ada sees this.")

    conn
    |> open("/")
    |> sign_out("/session")
    |> refute_has(".alert-success")

    # Not a page the second tab asked for: its socket was closed under it, the client reconnected,
    # and the gate turned it away. Without the disconnect it would sit there indefinitely, still
    # rendering an account that no longer has a session.
    refute_has(other, "p", text: "Only ada sees this.")
  end

  test "sign out everywhere disconnects another browser with its own session", context do
    first = context.conn
    second = another_browser(context)
    virtual_authenticator(first)

    [code | _] = first |> register("ada") |> recovery_codes()

    second
    |> open("/")
    |> fill_in("Lost your passkey? Use a recovery code", with: code)
    |> click_button("Sign in with a code")
    |> assert_has(".alert-success", text: "Signed in as ada")
    |> open("/inside")
    |> assert_has("p", text: "Only ada sees this.")

    account = Repo.get_by!(User, username: "ada")
    assert Repo.aggregate(Ecto.assoc(account, :sessions), :count) == 2

    first
    |> open("/")
    |> sign_out("/sessions")
    |> refute_has(".alert-success")

    second |> assert_path("/") |> refute_has("p", text: "Only ada sees this.")
    assert Repo.aggregate(Ecto.assoc(account, :sessions), :count) == 0
  end

  # The server-side refusal is pinned in `test/ithibati_open/auth_test.exs`, and it cannot also be
  # driven from here: the `pattern` attribute is derived from the same regex the server validates
  # with, so the browser refuses everything the server would. What this proves is that the derived
  # attribute reached the DOM and is doing its job, which no Elixir test can see.
  test "a name the server would refuse never leaves the browser", %{conn: conn} do
    virtual_authenticator(conn)

    conn
    |> open("/")
    |> fill_in("Username", with: "Ada Lovelace!")

    refute value_of(conn, "() => document.querySelector('input[name=username]').checkValidity()")

    click_button(conn, "Register")

    # Nothing was minted and nobody is left holding a passkey for an account that does not exist.
    # Asserted against the database and the authenticator rather than against the page, because a
    # page that has not navigated yet looks the same either way.
    assert credentials(conn) == []
    assert Repo.aggregate(User, :count) == 0
  end

  # Disconnecting the current socket may remount the public page before the HTTP redirect
  # replaces its document. Wait for that replacement before interacting with the next form.
  defp sign_out(conn, path) do
    conn
    |> evaluate("window.ithibatiLogoutPending = true")
    |> click("a[href='#{path}']")
    |> eventually("() => window.ithibatiLogoutPending !== true")
    |> connected()
  end
end
