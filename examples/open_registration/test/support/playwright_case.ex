defmodule IthibatiOpenWeb.PlaywrightCase do
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
        IthibatiOpen.DataCase.setup_sandbox(tags)
        %{conn: Fluffy.PhoenixTest.start_session(:playwright)}
      end

      setup %{conn: conn}, do: IthibatiOpenWeb.PlaywrightCase.fail_on_page_errors(conn)

      import Fluffy.PhoenixTest
      import IthibatiOpenWeb.PlaywrightCase
      import Ithibati.Testing.Passkeys

      alias IthibatiOpen.Accounts.User
      alias IthibatiOpen.Repo
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

  @doc """
  Registers `username` with a passkey and lands on the recovery codes.

  Several features need this preamble before their own subject. It asserts the landing, so a
  failure here names the registration.
  """
  def register(conn, username) do
    conn
    |> visit("/")
    |> fill_in("Username", with: username)
    |> click_button("Register")
    |> assert_path("/recovery-codes")
    |> assert_has("h1", text: "Your recovery codes")
  end

  @doc """
  Opens `path` in a second tab of the same browser and returns that tab.

  The tab shares the browser's cookies, so it carries the same session.
  `fail_on_page_errors/1` covers it, because it watches the whole browser context.
  Unlike the first tab, it does not answer dialogs.
  """
  def second_tab(conn, path) do
    page = Fluffy.Playwright.new_page(conn)
    conn |> Fluffy.Playwright.switch_page(page) |> visit(path)
  end

  @doc "Starts a second browser with its own cookies, for a test about two sessions."
  def another_browser(_context) do
    conn = start_session(:playwright)
    fail_on_page_errors(conn)
    conn
  end

  @doc "Returns the twelve recovery codes the page shows."
  def recovery_codes(conn) do
    conn
    |> assert_has("main li", count: 12)
    |> Fluffy.all_text_contents(Fluffy.Locator.by_css("main li"))
    |> Enum.map(&String.trim/1)
  end

  @doc "Runs the JavaScript `expression` in the page, a function called with `arg`, and returns `conn`."
  def evaluate(conn, expression, arg \\ nil) do
    Fluffy.Playwright.evaluate(conn, expression, arg)
    conn
  end
end
