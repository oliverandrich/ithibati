defmodule IthibatiOpenWeb.HookFailuresTest do
  @moduledoc """
  The half of the hook nobody had ever watched fail.

  Each of these is a different branch of the `catch` in `run/2`, and each reports a different
  reason — a library that collapsed them would hand a consumer "something went wrong" for a wiring
  mistake they could have fixed in a second.

  None of it needs test-only code in the example: the wiring lives in data attributes and the
  dialog lives in `navigator.credentials`, so a test can spoil either from the outside.
  """
  use IthibatiOpenWeb.PlaywrightCase

  # Setting the value instead of `fill_in/3`, because filling dispatches the `input` event that
  # `phx-change="validate"` listens for — and the patch that comes back restores every `data-`
  # attribute in the template, including the one the test just spoiled. Not starting the round trip
  # is the fix; `phx-submit` serialises the form from the DOM, so the server still sees the name.
  defp type(conn, value) do
    evaluate(conn, "value => { document.querySelector('input[name=username]').value = value }",
      is_function: true,
      arg: value
    )
  end

  # Spoiled, and kept spoiled.
  #
  # A `data-` attribute set from the outside is the template's to put back: any patch LiveView
  # applies to this container restores it, and the hook reads the attribute when the event fires,
  # not when the page loaded. Waiting is not a fix — `phx-connected` is already set *after* the
  # join patch (`hideLoader/0` is the last thing `applyJoinPatch/4` does, one call site), so a
  # single wait cannot cover a later patch or a reconnect, and this failed on CI while every local
  # run was green.
  #
  # An observer that re-applies has no window at all, where a retry loop only narrows one. It is
  # also honest about what the test needs: the hook still reads a real attribute off a real
  # element, exactly as it would in a browser somebody is using.
  defp spoil(conn, attribute, value) do
    evaluate(
      conn,
      """
      ([attribute, value]) => {
      const element = document.getElementById('passkey')

      // Compared before writing, or the observer's own change wakes it again, forever.
      const apply = () => {
        // Playwright passes nil as undefined, so the loose comparison covers both.
        if (value == null) {
          if (element.hasAttribute(attribute)) element.removeAttribute(attribute)
        } else if (element.getAttribute(attribute) !== value) {
          element.setAttribute(attribute, value)
        }
      }

      apply()
      new MutationObserver(apply).observe(element, {attributes: true, attributeFilter: [attribute]})
      }
      """,
      is_function: true,
      arg: [attribute, value]
    )

    # Read back off the element rather than through a CSS query. `assert_has/3` counts only
    # visible elements, and this one is deliberately empty: it renders nothing and carries only the
    # hook and these four paths. The test asks whether the element carries the attribute.
    assert attribute_of(conn, attribute) == value,
           "#{attribute} is #{inspect(attribute_of(conn, attribute))}, expected #{inspect(value)}"

    conn
  end

  # The one thing no amount of clicking produces: a browser that refuses. Each caller differs only
  # in which call it spoils and which `DOMException` name comes back, and `name` is all the hook
  # branches on.
  defp refuses(conn, method, name) do
    evaluate(
      conn,
      """
      ([method, name]) => {
      // A real `DOMException`, not an `Error` wearing its name: the hook only passes the name on
      // for the former, because only the browser's own refusals are named usefully.
      navigator.credentials[method] = () => Promise.reject(new DOMException(name, name))
      }
      """,
      is_function: true,
      arg: [method, name]
    )
  end

  defp attribute_of(conn, attribute) do
    value_of(
      conn,
      "attribute => document.getElementById('passkey').getAttribute(attribute)",
      attribute
    )
  end

  test "a missing data attribute is named, not reported as a failed ceremony", %{conn: conn} do
    virtual_authenticator(conn)

    conn
    |> open("/")
    |> type("ada")
    |> spoil("data-registration-url", nil)
    |> click_button("Register")
    # The attribute's own spelling, so the message says which one to go and add. Reported by name
    # because a wiring mistake otherwise looks exactly like somebody dismissing the dialog.
    |> assert_has(".alert-error", text: "missing_data_registration_url")
  end

  test "a response that is not JSON reports its status rather than nothing at all", %{conn: conn} do
    virtual_authenticator(conn)

    # A 404 whose body is an HTML error page: `response.json()` throws, the body becomes `{}`, and
    # there is no `error` key to report. Answering "unknown" there is what this actually did once,
    # and it told nobody anything — the status is the only thing that does.
    conn
    |> open("/")
    |> type("ada")
    |> spoil("data-registration-challenge-url", "/no-such-route")
    |> click_button("Register")
    |> assert_has(".alert-error", text: "http_404")
    |> refute_has(".alert-error", text: "unknown")
  end

  test "a dismissed prompt is reported as cancelled, and no account is left behind", %{conn: conn} do
    virtual_authenticator(conn)

    conn
    |> open("/")
    # WebAuthn reports a dismissed dialog as a `NotAllowedError`, and turning that into
    # `ceremony_cancelled` instead of a failure that names the server is the hook's job.
    |> refuses("create", "NotAllowedError")
    |> refuses("get", "NotAllowedError")
    |> fill_in("Username", with: "ada")
    |> click_button("Register")
    |> assert_has(".alert-error", text: "The passkey prompt was dismissed.")

    assert credentials(conn) == []
    assert Repo.aggregate(User, :count) == 0
  end

  test "an authenticator that already holds a passkey says so", %{conn: conn} do
    virtual_authenticator(conn)

    # What the browser answers when `excludeCredentials` already names a credential this
    # authenticator holds. The server never hears about it, so the word can only come from the
    # hook, and it is the same word the server uses when a browser ignores the exclude list.
    conn
    |> open("/")
    |> refuses("create", "InvalidStateError")
    |> fill_in("Username", with: "ada")
    |> click_button("Register")
    |> assert_has(".alert-error", text: "That device already holds a passkey for this site.")
  end

  test "the same browser error means nothing of the kind when signing in", %{conn: conn} do
    virtual_authenticator(conn)

    # A real registration first, or the challenge endpoint answers `no_credentials` and the browser
    # is never asked at all. What this test is about is what the *browser* refuses.
    register(conn, "ada")

    conn
    |> open("/")
    # `navigator.credentials.get` raises this when the document is not fully active, which a
    # restore from the back-forward cache produces. Nothing about it says the device is enrolled,
    # and a word scoped to registration must not be reachable from here.
    |> refuses("get", "InvalidStateError")
    |> click_button("Sign in with a passkey")
    # Not the enrolment sentence, and the name the browser gave rather than a shrug. Nothing here
    # translates `InvalidStateError`, because on this ceremony it does not mean what it means on
    # the other one.
    |> assert_has(".alert-error", text: "Your browser refused: InvalidStateError.")
    |> refute_has(".alert-error", text: "already holds a passkey")
  end

  test "a refusal the server named is shown as the server's own reason", %{conn: conn} do
    virtual_authenticator(conn)

    register(conn, "ada")

    # A second registration for the name that now exists. The reason travels from the handler through
    # the JSON body, the hook and `ithibati:failed` into a sentence — the chain the README
    # describes and nothing executed until the browser tests did.
    conn
    |> open("/")
    |> fill_in("Username", with: "ada")
    |> click_button("Register")
    |> assert_has(".alert-error", text: "That username is taken.")
  end
end
