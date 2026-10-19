if Code.ensure_loaded?(PhoenixTest.Playwright) do
  defmodule Ithibati.Testing.Passkeys do
    @moduledoc """
    A virtual authenticator for browser tests with `PhoenixTest.Playwright`.

    A passkey ceremony needs an authenticator in the browser. Chrome emulates one through the
    WebAuthn domain of the Chrome DevTools Protocol. This module reaches it over a CDP session on
    the test's page. It works with Playwright's Chromium only.

    Playwright's own `credentials` API cannot serve this library. Its synthetic credential returns
    an empty `toJSON()`, and the shipped JavaScript serialises credentials with `toJSON()`.

        test "a passkey signs back in", %{conn: conn} do
          authenticator = virtual_authenticator(conn)
          # ... register through the page ...
          assert length(credentials(conn, authenticator)) == 1
        end

    The module exists only when `phoenix_test_playwright` is a dependency.
    """

    alias PhoenixTest.Playwright.Config
    alias PlaywrightEx.Connection

    @doc """
    Adds a virtual platform authenticator to the page and returns its id.

    The authenticator holds discoverable credentials, verifies the user and answers every prompt
    by itself. No credential is seeded, so each test registers its own passkey.
    """
    def virtual_authenticator(conn) do
      command(conn, "WebAuthn.enable", %{})

      conn
      |> command("WebAuthn.addVirtualAuthenticator", %{
        options: %{
          protocol: "ctap2",
          # A platform authenticator such as Touch ID or Windows Hello holds web passkeys.
          transport: "internal",
          hasResidentKey: true,
          hasUserVerification: true,
          isUserVerified: true,
          automaticPresenceSimulation: true
        }
      })
      |> Map.fetch!(:authenticator_id)
    end

    @doc """
    Removes the authenticator `id` from the page and returns `conn`.

    Chrome keeps one platform authenticator per page. Removing it lets a new one model a second
    device.
    """
    def remove_authenticator(conn, id) do
      command(conn, "WebAuthn.removeVirtualAuthenticator", %{authenticatorId: id})
      conn
    end

    @doc """
    Returns the credentials the authenticator `id` holds.

    A ceremony that reached `navigator.credentials.create` leaves one here.
    """
    def credentials(conn, id) do
      conn
      |> command("WebAuthn.getCredentials", %{authenticatorId: id})
      |> Map.fetch!(:credentials)
    end

    # A virtual authenticator lives only as long as the CDP session that added it.
    # So the session is opened once per page and kept in the test process.
    # playwright_ex has no wrapper for `newCDPSession`, so the method is sent by its protocol name.
    # playwright_ex turns a reply key into an atom only when that atom exists.
    # The keys read here exist, because this module names them as literals.
    defp command(conn, method, params) do
      %{result: result} = send!(cdp_session(conn), :send, %{method: method, params: params})
      result
    end

    defp cdp_session(%{context_id: context, page_id: page}) do
      with nil <- Process.get({__MODULE__, page}) do
        %{session: %{guid: session}} = send!(context, "newCDPSession", %{page: %{guid: page}})
        Process.put({__MODULE__, page}, session)
        session
      end
    end

    defp send!(guid, method, params) do
      message = %{guid: guid, method: method, params: params}

      case Connection.send(
             PlaywrightEx.Supervisor.connection_name(),
             message,
             Config.global(:timeout)
           ) do
        %{error: error} -> raise "#{method} failed: #{inspect(error)}"
        reply -> Map.get(reply, :result, %{})
      end
    end
  end
end
