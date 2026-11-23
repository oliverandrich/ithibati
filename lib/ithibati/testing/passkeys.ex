if Code.ensure_loaded?(Fluffy) do
  defmodule Ithibati.Testing.Passkeys do
    @moduledoc """
    A virtual authenticator for browser tests with Fluffy's Playwright backend.

    A passkey ceremony needs an authenticator in the browser. This module installs Playwright's
    virtual WebAuthn authenticator (`Playwright.Credentials`) in the test's browser context, so it
    works in every browser Playwright drives. Pages of the same context share it.

    The authenticator replaces `navigator.credentials` with a script. It returns no extension
    results and does not check the relying party id against the origin; the server still does.

        test "a passkey signs back in", %{conn: conn} do
          virtual_authenticator(conn)
          # ... register through the page ...
          assert length(credentials(conn)) == 1
        end

    The module exists only when `fluffy` is a dependency.
    """

    alias Playwright.BrowserContext
    alias Playwright.Credentials

    @doc """
    Adds a virtual platform authenticator to the browser context and returns `conn`.

    The authenticator holds discoverable credentials, verifies the user and answers every prompt
    by itself. No credential is seeded, so each test registers its own passkey. A second call on
    the same context does nothing.
    """
    def virtual_authenticator(conn) do
      conn |> authenticator() |> Credentials.install!()
      conn
    end

    @doc """
    Returns the credentials the authenticator holds.

    A ceremony that reached `navigator.credentials.create` leaves one here.
    """
    def credentials(conn), do: conn |> authenticator() |> Credentials.get!()

    @doc """
    Deletes every credential the authenticator holds and returns `conn`.

    The authenticator then holds no passkey, like a device that never registered one.
    """
    def forget_credentials(conn) do
      authenticator = authenticator(conn)
      for %{id: id} <- Credentials.get!(authenticator), do: Credentials.delete!(authenticator, id)
      conn
    end

    defp authenticator(conn) do
      %Playwright.Page{} = page = Fluffy.PhoenixTest.unwrap_and_return(conn, & &1)
      page |> Playwright.Page.context() |> BrowserContext.credentials()
    end
  end
end
