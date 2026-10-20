if Code.ensure_loaded?(PhoenixTest.Playwright) do
  defmodule Ithibati.Testing.Passkeys do
    @moduledoc """
    A virtual authenticator for browser tests with `PhoenixTest.Playwright`.

    A passkey ceremony needs an authenticator in the browser. Chrome emulates one through the
    WebAuthn domain of the Chrome DevTools Protocol. This module reaches it over a CDP session on
    the test's page. It works with Playwright's Chromium only.

    Playwright's own `credentials` API replaces `navigator.credentials` with a script. In
    Playwright 1.64 that script returns no extension results and does not check the relying party
    id against the origin. The CDP authenticator runs behind Chrome's WebAuthn client.

    The authenticator id and the CDP session are kept in the test process. Call these functions
    from that process.

        test "a passkey signs back in", %{conn: conn} do
          virtual_authenticator(conn)
          # ... register through the page ...
          assert length(credentials(conn)) == 1
        end

    The module exists only when `phoenix_test_playwright` is a dependency.
    """

    alias PhoenixTest.Playwright.Config
    alias PlaywrightEx.Connection

    @doc """
    Adds a virtual platform authenticator to the page and returns `conn`.

    The authenticator holds discoverable credentials, verifies the user and answers every prompt
    by itself. No credential is seeded, so each test registers its own passkey. A second call on
    the same page does nothing.
    """
    def virtual_authenticator(%{context_id: context, page_id: page} = conn) do
      with nil <- Process.get({__MODULE__, page}) do
        # A virtual authenticator lives only as long as the CDP session that added it.
        # So the session is kept in the test process with the authenticator's id.
        # playwright_ex has no wrapper for `newCDPSession`, so the method is sent by its protocol name.
        %{session: %{guid: session}} = send!(context, "newCDPSession", %{page: %{guid: page}})
        command(session, "WebAuthn.enable", %{})

        %{authenticator_id: id} =
          command(session, "WebAuthn.addVirtualAuthenticator", %{
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

        Process.put({__MODULE__, page}, %{session: session, id: id})
      end

      conn
    end

    @doc """
    Returns the credentials the page's authenticator holds.

    A ceremony that reached `navigator.credentials.create` leaves one here.
    """
    def credentials(conn) do
      %{session: session, id: id} = authenticator!(conn)

      session
      |> command("WebAuthn.getCredentials", %{authenticatorId: id})
      |> Map.fetch!(:credentials)
    end

    @doc """
    Deletes every credential the page's authenticator holds and returns `conn`.

    The authenticator then holds no passkey, like a device that never registered one.
    """
    def forget_credentials(conn) do
      %{session: session, id: id} = authenticator!(conn)
      command(session, "WebAuthn.clearCredentials", %{authenticatorId: id})
      conn
    end

    defp authenticator!(%{page_id: page}) do
      Process.get({__MODULE__, page}) ||
        raise "no virtual authenticator on this page; call virtual_authenticator/1 first"
    end

    # playwright_ex turns a reply key into an atom only when that atom exists.
    # The keys read here exist, because this module names them as literals.
    defp command(session, method, params) do
      %{result: result} = send!(session, :send, %{method: method, params: params})
      result
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
