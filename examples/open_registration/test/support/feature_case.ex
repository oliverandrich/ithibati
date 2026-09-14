defmodule IthibatiOpenWeb.FeatureCase do
  @moduledoc """
  A real browser, driving the real pages — and with them `priv/static/ithibati.js`, the half of
  Ithibati that runs on somebody else's machine.

  These are not `Phoenix.LiveViewTest` tests and cannot be: a passkey ceremony is
  `navigator.credentials`, a `fetch` that sets a cookie, and a redirect the hook follows. None of
  that exists without a browser.

  Wallaby shares the test's sandboxed connection with the server, so a test may look in the
  database at what the browser just did — which is how these assert that a ceremony *arrived*
  rather than only that a page changed.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.Feature

      import IthibatiOpenWeb.FeatureCase
      import Wallaby.Query

      alias IthibatiOpen.Accounts.User
      alias IthibatiOpen.Repo
    end
  end

  @doc """
  Goes to a page and waits until its LiveView has actually connected.

  Use this rather than `visit/2` for anything these tests then interact with. A page answers long
  before its socket does, and until it does, `phx-submit` is not wired and the mount patch has not
  run — so a click goes nowhere, and a `data-` attribute spoiled beforehand is quietly put back to
  what the template says. Measured: without the wait the suite failed about one run in three, on a
  different test each time, which reads as flakiness rather than as the race it is.
  """
  def open(session, path) do
    session |> Wallaby.Browser.visit(path) |> connected()
  end

  @doc """
  Waits where the browser already is, for a page it reached by clicking rather than by `open/2`.

  Same race, same reason: a full page load leaves a document that answers before its socket does,
  and a `phx-click` on it goes nowhere until the view has joined.
  """
  def connected(session) do
    # `find/2` blocks and raises if it never appears, which is the waiting and the check in one.
    Wallaby.Browser.find(session, Wallaby.Query.css("[data-phx-main].phx-connected"))

    session
  end

  @doc """
  Attaches a virtual authenticator to this session's browser.

  Chrome's own, reached through chromedriver's CDP passthrough. Wallaby's `browserContext`
  equivalent — Playwright's first-class `credentials` API — cannot serve this library: it hands the
  page a synthetic credential whose `toJSON()` comes back empty, and `toJSON()` is exactly what the
  library serialises with. Nothing is ever seeded: these tests register their own passkey, which is
  the property worth proving.
  """
  def virtual_authenticator(session) do
    command(session, "WebAuthn.enable", %{})

    %{"authenticatorId" => id} =
      command(session, "WebAuthn.addVirtualAuthenticator", %{
        options: %{
          protocol: "ctap2",
          # A platform authenticator — Touch ID, Windows Hello — which is what a passkey for a web
          # application actually is.
          transport: "internal",
          hasResidentKey: true,
          hasUserVerification: true,
          isUserVerified: true,
          automaticPresenceSimulation: true
        }
      })

    id
  end

  @doc """
  Throws away every cookie this browser holds, signing it out.

  Through WebDriver rather than `document.cookie`: the session cookie is `HttpOnly`, so JavaScript
  cannot see it, let alone expire it — measured, `document.cookie` answers `""` on a signed-in
  page. A test that cleared it that way would go on being signed in and would quietly stop
  exercising whatever it opened a fresh session to show.
  """
  def clear_cookies(session) do
    {:ok, _} = Wallaby.HTTPClient.request(:delete, "#{session.url}/cookie")

    session
  end

  @doc "Every credential the *page* registered, so a test can say whether a ceremony reached one."
  def credentials(session, authenticator) do
    %{"credentials" => credentials} =
      command(session, "WebAuthn.getCredentials", %{authenticatorId: authenticator})

    credentials
  end

  # chromedriver answers the WebDriver envelope — `sessionId`, `status`, `value` — and what CDP
  # returned is inside `value`.
  defp command(session, cmd, params) do
    {:ok, %{"value" => value}} =
      Wallaby.HTTPClient.request(:post, "#{session.url}/chromium/send_command_and_get_result", %{
        cmd: cmd,
        params: params
      })

    value
  end
end
