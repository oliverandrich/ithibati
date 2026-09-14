defmodule IthibatiOpenWeb.RegistrationTest do
  @moduledoc """
  The ceremonies, in a browser, through the JavaScript this library ships.

  A green run here says the shipped client code works — not that a copy of it does: the example
  bundles `priv/static/ithibati.js` with esbuild, and that bundle is what the page loads.
  """
  use IthibatiOpenWeb.FeatureCase

  # The prelude the first test walks through with its own assertions, so that the tests about
  # something else can reach their subject in a line — the shape `invitation_test.exs` uses too.
  defp register(session, username) do
    session
    |> open("/")
    |> fill_in(css("input[name=username]"), with: username)
    |> click(button("Register"))
    |> assert_has(css("h1", text: "Your recovery codes"))
  end

  feature "a passkey is made, the codes are shown once, and the same passkey signs back in", %{
    session: session
  } do
    authenticator = virtual_authenticator(session)

    session
    |> open("/")
    |> fill_in(css("input[name=username]"), with: "ada")
    |> click(button("Register"))
    # The handler answers `%{redirect: "/recovery-codes"}` and the hook acts on it with a full page
    # load, which a sign-in needs anyway: renewing the session takes the CSRF token with it.
    |> assert_has(css("h1", text: "Your recovery codes"))
    |> assert_has(css("main li", count: 12))

    # The rows, not only the page: this is what `malformed_credential` would have prevented, and
    # reading it in the same sandboxed connection the browser wrote through is what a browser
    # driven from outside the application cannot do.
    assert account = Repo.get_by(User, username: "ada")
    assert Repo.aggregate(Ecto.assoc(account, :passkeys), :count) == 1
    assert Repo.aggregate(Ecto.assoc(account, :recovery_codes), :count) == 12

    # And the authenticator kept what the *page* registered, which is how we know the ceremony
    # reached `navigator.credentials.create` rather than being simulated around it.
    assert length(credentials(session, authenticator)) == 1

    session
    |> open("/inside")
    |> assert_has(css("p", text: "Only ada sees this."))
    |> open("/")
    |> click(link("sign out"))
    |> refute_has(css(".alert-success", text: "Signed in as"))
    # Signing out is a full page load, and the button below is a `phx-click`: without this the
    # click lands on a document whose socket has not joined and does nothing at all.
    |> connected()

    # Usernameless: the sign-in names no credential at all, so this only works because the
    # credential is discoverable — the property `registration_options/3` refuses to leave to the
    # authenticator's discretion.
    session
    |> click(button("Sign in with a passkey"))
    |> assert_has(css(".alert-success", text: "Signed in as ada"))
  end

  # The bug `Ithibati.Web.Gate` closes: a revoked token stops the *next* request and the next
  # mount, while a LiveView already connected holds its account in assigns and goes on accepting
  # events as that account until something tells its socket to go away.
  feature "signing out in one tab ends a LiveView left open in another", %{session: session} do
    virtual_authenticator(session)
    register(session, "ada")

    # A second tab of the same browser, so the same cookie.
    [first] = window_handles(session)
    execute_script(session, "window.open('/inside', '_blank')")

    # `execute_script/2` returns when the script does; the handle appearing in WebDriver's window
    # list is not synchronised with that, and matching too early dies with a `MatchError` rather
    # than saying what went wrong.
    {:ok, other} =
      retry(fn ->
        case window_handles(session) -- [first] do
          [handle] -> {:ok, handle}
          _none -> {:error, :not_yet}
        end
      end)

    session
    |> focus_window(other)
    |> assert_has(css("p", text: "Only ada sees this."))

    session
    |> focus_window(first)
    |> open("/")
    |> click(link("sign out"))
    |> refute_has(css(".alert-success", text: "Signed in as"))

    # Not a page the second tab asked for: its socket was closed under it, the client reconnected,
    # and the gate turned it away. Without the disconnect it would sit there indefinitely, still
    # rendering an account that no longer has a session.
    session
    |> focus_window(other)
    |> refute_has(css("p", text: "Only ada sees this."))
  end

  # The server-side refusal is pinned in `test/ithibati_open/auth_test.exs`, and it cannot also be
  # driven from here: the `pattern` attribute is derived from the same regex the server validates
  # with, so the browser refuses everything the server would. What this proves is that the derived
  # attribute reached the DOM and is doing its job, which no Elixir test can see.
  feature "a name the server would refuse never leaves the browser", %{session: session} do
    authenticator = virtual_authenticator(session)

    session
    |> open("/")
    |> fill_in(css("input[name=username]"), with: "Ada Lovelace!")

    refute execute_script_value(
             session,
             "return document.querySelector('input[name=username]').checkValidity()"
           )

    click(session, button("Register"))

    # Nothing was minted and nobody is left holding a passkey for an account that does not exist.
    # Asserted against the database and the authenticator rather than against the page, because a
    # page that has not navigated yet looks the same either way.
    assert credentials(session, authenticator) == []
    assert Repo.aggregate(User, :count) == 0
  end

  # `execute_script/4` runs the callback in this process before it returns, so the answer is already
  # waiting by the time we look.
  defp execute_script_value(session, script) do
    execute_script(session, script, [], &send(self(), {:script, &1}))

    receive do
      {:script, value} -> value
    end
  end
end
