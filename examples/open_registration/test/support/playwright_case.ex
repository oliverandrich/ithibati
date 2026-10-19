defmodule IthibatiOpenWeb.PlaywrightCase do
  @moduledoc """
  Case template for browser features in Playwright's Chrome for Testing.

  A passkey ceremony needs `navigator.credentials`, a `fetch` that sets a cookie, and a redirect
  the hook follows. `Phoenix.LiveViewTest` has none of these, so these features drive a browser.
  They are also the only tests that execute `priv/static/ithibati.js`.

  The sandbox runs in shared mode, so a test can read in the database what the browser stored.
  """
  use ExUnit.CaseTemplate

  import PhoenixTest

  alias PhoenixTest.Playwright.Config
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Connection
  alias PlaywrightEx.Frame

  using do
    quote do
      use PhoenixTest.Playwright.Case

      setup %{conn: conn}, do: IthibatiOpenWeb.PlaywrightCase.fail_on_page_errors(conn)

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
  def fail_on_page_errors(%{context_id: context}) do
    collector = spawn(fn -> collect_page_errors([]) end)
    :ok = Connection.subscribe(PlaywrightEx.Supervisor.connection_name(), collector, context)

    on_exit(fn ->
      send(collector, {:page_errors, self()})

      receive do
        {:page_errors, []} -> :ok
        {:page_errors, errors} -> flunk("the page threw:\n\n" <> Enum.join(errors, "\n\n"))
      after
        Config.global(:timeout) ->
          Process.exit(collector, :kill)
          flunk("the page error collector did not answer")
      end
    end)
  end

  defp collect_page_errors(errors) do
    receive do
      {:playwright_msg, %{method: :page_error, params: params}} ->
        collect_page_errors([page_error_message(params) | errors])

      {:page_errors, pid} ->
        send(pid, {:page_errors, Enum.reverse(errors)})

      _other ->
        collect_page_errors(errors)
    end
  end

  defp page_error_message(%{error: %{error: %{message: message}}}), do: message
  defp page_error_message(params), do: inspect(params)

  @doc """
  Visits `path` and waits until its LiveView is connected.

  The page answers before its socket joins. Until then `phx-submit` is not bound, so a click goes
  nowhere. Measured: without the wait about one suite run in three failed.
  """
  def open(conn, path), do: conn |> visit(path) |> connected()

  @doc "Waits until the current page's LiveView is connected, for a page reached by a click."
  def connected(conn), do: assert_has(conn, "[data-phx-main].phx-connected")

  @doc """
  Registers `username` with a passkey and lands on the recovery codes.

  Several features need this preamble before their own subject. It asserts the landing, so a
  failure here names the registration.
  """
  def register(conn, username) do
    conn
    |> open("/")
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
    {:ok, page} = BrowserContext.new_page(conn.context_id, timeout: Config.global(:timeout))
    open(%{conn | page_id: page.guid, frame_id: page.main_frame.guid}, path)
  end

  @doc "Starts a second browser with its own cookies, for a test about two sessions."
  def another_browser(context) do
    conn = PhoenixTest.Playwright.Case.new_session(Config.global(), context)
    fail_on_page_errors(conn)
    conn
  end

  @doc "Returns the twelve recovery codes the page shows."
  def recovery_codes(conn) do
    conn
    |> assert_has("main li", count: 12)
    |> value_of(
      "() => Array.from(document.querySelectorAll('main li'), li => li.textContent.trim())"
    )
  end

  @doc """
  Calls the JavaScript function `function` in the page with `arg` and returns its result.

  The function may return a Promise. The test receives what it resolves to.
  """
  def value_of(%{frame_id: frame}, function, arg \\ nil) do
    opts = [expression: function, is_function: true, arg: arg, timeout: Config.global(:timeout)]

    case Frame.evaluate(frame, opts) do
      {:ok, value} -> value
      {:error, error} -> flunk("the script failed: #{inspect(error)}\n\n#{function}")
    end
  end

  @doc """
  Waits until the JavaScript function `function` returns a truthy value in the page.

  For page state no selector can express. The browser polls on each animation frame.
  """
  def eventually(%{frame_id: frame} = conn, function) do
    opts = [
      expression: function,
      is_function: true,
      polling: "raf",
      timeout: Config.global(:timeout)
    ]

    assert {:ok, _} = Frame.wait_for_function(frame, opts), "never true: #{function}"
    conn
  end
end
