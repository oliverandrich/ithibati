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
  defp spoil(session, attribute, value) do
    execute_script(
      session,
      """
      const element = document.getElementById('passkey')
      const [attribute, value] = [arguments[0], arguments[1]]

      // Compared before writing, or the observer's own change wakes it again, forever.
      const apply = () => {
        if (value === null) {
          if (element.hasAttribute(attribute)) element.removeAttribute(attribute)
        } else if (element.getAttribute(attribute) !== value) {
          element.setAttribute(attribute, value)
        }
      }

      apply()
      new MutationObserver(apply).observe(element, {attributes: true, attributeFilter: [attribute]})
      """,
      [attribute, value]
    )

    # Read back off the element rather than through a CSS query, because `Wallaby.Query.css/2`
    # filters on *visibility* by default and this element is deliberately empty — it renders
    # nothing and exists only to carry the hook and these four paths. Locally it measures 672×0 and
    # counts as displayed anyway; on CI the same query found nothing while the attribute was set,
    # which cost a red build and a wrong diagnosis. What the test means is "the element carries
    # this", and that is a question with no visibility in it.
    assert attribute_of(session, attribute) == value,
           "#{attribute} is #{inspect(attribute_of(session, attribute))}, expected #{inspect(value)}"

    session
  end

  defp attribute_of(session, attribute) do
    execute_script(
      session,
      "return document.getElementById('passkey').getAttribute(arguments[0])",
      [attribute],
      &send(self(), {:attribute, &1})
    )

    receive do
      {:attribute, value} -> value
    end
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
    |> landed_on("/recovery-codes")
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
