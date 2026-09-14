defmodule IthibatiOpenWeb.HookFailuresTest do
  @moduledoc """
  The half of the hook nobody had ever watched fail.

  Each of these is a different branch of the `catch` in `run/2`, and each reports a different
  reason — a library that collapsed them would hand a consumer "something went wrong" for a wiring
  mistake they could have fixed in a second.

  None of it needs test-only code in the example: the wiring lives in data attributes and the
  dialog lives in `navigator.credentials`, so a test can spoil either from the outside.
  """
  use IthibatiOpenWeb.FeatureCase

  # Setting the value instead of `fill_in/3`, because filling dispatches the `input` event that
  # `phx-change="validate"` listens for — and the patch that comes back restores every `data-`
  # attribute in the template, including the one the test just spoiled. Not starting the round trip
  # is the fix; `phx-submit` serialises the form from the DOM, so the server still sees the name.
  defp type(session, value) do
    execute_script(
      session,
      "document.querySelector('input[name=username]').value = arguments[0]",
      [value]
    )
  end

  defp spoil(session, attribute, nil) do
    execute_script(session, "document.getElementById('passkey').removeAttribute(arguments[0])", [
      attribute
    ])

    refute_has(session, css("#passkey[#{attribute}]"))
  end

  defp spoil(session, attribute, value) do
    execute_script(
      session,
      "document.getElementById('passkey').setAttribute(arguments[0], arguments[1])",
      [attribute, value]
    )

    # Read back rather than assumed: these tests are about what the hook does when the element is
    # wrong, and an element a LiveView patch quietly put right again tests nothing — it would fail
    # on the message assertion instead, which says nothing about why.
    assert_has(session, css("#passkey[#{attribute}='#{value}']"))
  end

  feature "a missing data attribute is named, not reported as a failed ceremony", %{
    session: session
  } do
    virtual_authenticator(session)

    session
    |> open("/")
    |> type("ada")
    |> spoil("data-registration-url", nil)
    |> click(button("Register"))
    # The attribute's own spelling, so the message says which one to go and add. Reported by name
    # because a wiring mistake otherwise looks exactly like somebody dismissing the dialog.
    |> assert_has(css(".alert-error", text: "missing_data_registration_url"))
  end

  feature "a response that is not JSON reports its status rather than nothing at all", %{
    session: session
  } do
    virtual_authenticator(session)

    # A 404 whose body is an HTML error page: `response.json()` throws, the body becomes `{}`, and
    # there is no `error` key to report. Answering "unknown" there is what this actually did once,
    # and it told nobody anything — the status is the only thing that does.
    session
    |> open("/")
    |> type("ada")
    |> spoil("data-registration-challenge-url", "/no-such-route")
    |> click(button("Register"))
    |> assert_has(css(".alert-error", text: "http_404"))
    |> refute_has(css(".alert-error", text: "unknown"))
  end

  feature "a dismissed prompt is reported as cancelled, and no account is left behind", %{
    session: session
  } do
    authenticator = virtual_authenticator(session)

    session
    |> open("/")
    # The one thing no amount of clicking produces. WebAuthn reports a dismissed dialog as a
    # `NotAllowedError`, and turning that into `ceremony_cancelled` rather than into a failure that
    # names the server is the hook's job.
    |> execute_script("""
    const refuse = () => {
      const error = new Error("The operation either timed out or was not allowed.")
      error.name = "NotAllowedError"
      return Promise.reject(error)
    }
    navigator.credentials.create = refuse
    navigator.credentials.get = refuse
    """)
    |> type("ada")
    |> click(button("Register"))
    |> assert_has(css(".alert-error", text: "The passkey prompt was dismissed."))

    assert credentials(session, authenticator) == []
    assert Repo.aggregate(User, :count) == 0
  end

  feature "a refusal the server named is shown as the server's own reason", %{session: session} do
    virtual_authenticator(session)

    session
    |> open("/")
    |> fill_in(css("input[name=username]"), with: "ada")
    |> click(button("Register"))
    |> assert_has(css("h1", text: "Your recovery codes"))

    # A second registration for the name that now exists. The reason travels from the handler through
    # the JSON body, the hook and `ithibati:failed` into a sentence — the chain the README
    # describes and nothing executed until the browser tests did.
    session
    |> open("/")
    |> fill_in(css("input[name=username]"), with: "ada")
    |> click(button("Register"))
    |> assert_has(css(".alert-error", text: "That username is taken."))
  end
end
