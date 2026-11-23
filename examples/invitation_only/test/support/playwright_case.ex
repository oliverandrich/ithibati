defmodule IthibatiInvitesWeb.PlaywrightCase do
  @moduledoc """
  Case template for browser features in Playwright's Chrome for Testing.

  A passkey ceremony needs `navigator.credentials`, a `fetch` that sets a cookie, and a redirect
  the hook follows. `Phoenix.LiveViewTest` has none of these, so these features drive a browser.
  They are also the only tests that execute `priv/static/ithibati.js`.

  The sandbox runs in shared mode, so a test can read in the database what the browser stored.
  """
  use ExUnit.CaseTemplate

  import Fluffy.PhoenixTest

  alias Playwright.BrowserContext

  using do
    quote do
      use Playwright.Test

      setup tags do
        IthibatiInvites.DataCase.setup_sandbox(tags)
        %{conn: Fluffy.PhoenixTest.start_session(:playwright)}
      end

      setup %{conn: conn}, do: IthibatiInvitesWeb.PlaywrightCase.fail_on_page_errors(conn)

      import Fluffy.PhoenixTest
      import IthibatiInvitesWeb.PlaywrightCase
      import Ithibati.Testing.Passkeys

      alias IthibatiInvites.Accounts.User
      alias IthibatiInvites.Repo
    end
  end

  @doc """
  Fails the feature after it ends if the page had an uncaught error.

  Playwright reports these errors as events of the browser context, which no assertion sees.
  The collector is not linked, because `on_exit` runs after the test process has exited.
  The check runs before the browser context closes, because `on_exit` callbacks run in reverse order.
  """
  def fail_on_page_errors(conn) do
    collector = spawn(fn -> collect_page_errors([]) end)
    context = unwrap_and_return(conn, &Playwright.Page.context/1)
    BrowserContext.on(context, :web_error, &send(collector, {:page_error, &1}))

    on_exit(fn ->
      send(collector, {:page_errors, self()})

      receive do
        {:page_errors, []} -> :ok
        {:page_errors, errors} -> flunk("the page threw:\n\n" <> Enum.join(errors, "\n\n"))
      after
        3_000 ->
          Process.exit(collector, :kill)
          flunk("the page error collector did not answer")
      end
    end)
  end

  defp collect_page_errors(errors) do
    receive do
      {:page_error, error} ->
        collect_page_errors([Exception.message(Playwright.WebError.error(error)) | errors])

      {:page_errors, pid} ->
        send(pid, {:page_errors, Enum.reverse(errors)})
    end
  end

  @doc "Clears the browser's cookies, so the next page starts signed out."
  def clear_cookies(%{session: session} = conn),
    do: %{conn | session: Fluffy.clear_cookies(session)}

  @doc """
  Calls the JavaScript function `function` in the page and returns its result.

  The function may return a Promise. The test receives what it resolves to.
  """
  def value_of(%{session: session}, function), do: Fluffy.Playwright.evaluate(session, function)
end
