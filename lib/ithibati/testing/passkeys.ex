if Code.ensure_loaded?(Fluffy) do
  defmodule Ithibati.Testing.Passkeys do
    @moduledoc """
    A virtual authenticator for browser tests with Fluffy's Playwright backend.

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

    The module exists only when `fluffy` is a dependency.
    """

    alias Playwright.BrowserContext
    alias Playwright.CDPSession

    @doc """
    Adds a virtual platform authenticator to the page and returns `conn`.

    The authenticator holds discoverable credentials, verifies the user and answers every prompt
    by itself. No credential is seeded, so each test registers its own passkey. A second call on
    the same page does nothing.
    """
    def virtual_authenticator(conn) do
      page = page!(conn)

      with nil <- Process.get({__MODULE__, page}) do
        # A virtual authenticator lives only as long as the CDP session that added it.
        # So the session is kept in the test process with the authenticator's id.
        session = page |> Playwright.Page.context() |> BrowserContext.new_cdp_session!(page)
        CDPSession.send!(session, "WebAuthn.enable")

        %{"authenticatorId" => id} =
          CDPSession.send!(session, "WebAuthn.addVirtualAuthenticator", %{
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
      |> CDPSession.send!("WebAuthn.getCredentials", %{authenticatorId: id})
      |> Map.fetch!("credentials")
    end

    @doc """
    Deletes every credential the page's authenticator holds and returns `conn`.

    The authenticator then holds no passkey, like a device that never registered one.
    """
    def forget_credentials(conn) do
      %{session: session, id: id} = authenticator!(conn)
      CDPSession.send!(session, "WebAuthn.clearCredentials", %{authenticatorId: id})
      conn
    end

    defp authenticator!(conn) do
      Process.get({__MODULE__, page!(conn)}) ||
        raise "no virtual authenticator on this page; call virtual_authenticator/1 first"
    end

    defp page!(conn), do: %Playwright.Page{} = Fluffy.PhoenixTest.unwrap_and_return(conn, & &1)
  end
end
