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

  # The test modules get this through the `using` block below; this module needs it too, because
  # `assert_has/2` is a macro that expands into `execute_query/2` and both have to be in scope here.
  import Wallaby.Browser

  alias Wallaby.Query

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
    session |> visit(path) |> connected()
  end

  @doc """
  Waits until the browser has actually arrived at a path, and answers the session.

  For the moment after a ceremony, where the hook follows the handler's `%{redirect: …}` with a
  full page load. Asserting on content across that swap is what produced the one failure this
  suite could not explain: Wallaby finds the elements, then asks Chrome whether each is visible,
  and if the document has been replaced in between Chrome answers *"Node with given id does not
  belong to the document"*. Wallaby's `execute_query/2` rescues `StaleReferenceError` and would
  have retried; this arrives as a bare `RuntimeError` from the HTTP client and escapes.

  `current_path/1` holds no element references, so it is safe to ask across the swap; once it
  answers, the document a later query finds is the new one. Where the redirect leads back to the
  page the browser is already on, this cannot help — see `through_navigation/1`.
  """
  def landed_on(session, path) do
    result =
      retry(fn ->
        case current_path(session) do
          ^path -> {:ok, session}
          other -> {:error, {:still_at, other}}
        end
      end)

    case result do
      {:ok, session} -> session
      {:error, {:still_at, other}} -> flunk("never reached #{path}; still at #{other}")
    end
  end

  @doc """
  Runs an assertion, and runs it again if the document was swapped underneath it.

  For the redirect `landed_on/2` cannot wait for: one that leads to the path the browser is already
  on, where the poll is satisfied before the navigation has even started. Signing in is that —
  the handler answers `%{redirect: "/"}` from a page already at `/`.

  So this one does not predict the swap; it notices it happened. Matching on Chrome's message is
  narrow, which is why it is confined to the single site that cannot be solved by waiting.
  """
  def through_navigation(session, query, attempts \\ 10) do
    assert_has(session, query)
  rescue
    error in RuntimeError ->
      if Exception.message(error) =~ "does not belong to the document" and attempts > 0 do
        through_navigation(session, query, attempts - 1)
      else
        reraise(error, __STACKTRACE__)
      end
  end

  @doc """
  Waits where the browser already is, for a page it reached by clicking rather than by `open/2`.

  Same race, same reason: a full page load leaves a document that answers before its socket does,
  and a `phx-click` on it goes nowhere until the view has joined.
  """
  def connected(session) do
    # `find/2` blocks and raises if it never appears, which is the waiting and the check in one.
    find(session, Query.css("[data-phx-main].phx-connected"))

    session
  end

  @doc """
  Registers an account and lands on the recovery codes, which is where a registration ends.

  Three feature files want this preamble before they can reach their own subject. It carries its
  own assertion so a test that fails here fails about the registration, not about whatever it was
  going to check next.
  """
  def register(session, username) do
    session
    |> open("/")
    |> fill_in(Wallaby.Query.css("input[name=username]"), with: username)
    |> click(Wallaby.Query.button("Register"))
    |> landed_on("/recovery-codes")
    |> assert_has(Wallaby.Query.css("h1", text: "Your recovery codes"))
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
