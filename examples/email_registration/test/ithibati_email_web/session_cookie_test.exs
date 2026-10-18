defmodule IthibatiEmailWeb.SessionCookieTest do
  @moduledoc """
  The browser keeps the session cookie as long as the server keeps the session.
  """
  use IthibatiEmailWeb.ConnCase, async: true

  alias Ithibati.Identity.Sessions

  test "the session cookie carries the session's validity as its max age", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert %{max_age: max_age} = conn.resp_cookies["_ithibati_email_key"]
    assert max_age == Sessions.max_age()
  end

  # Recovery codes wait in the session until their page shows them. A signed cookie is only
  # Base64, so a copy of it would reveal codes that outlive the session.
  test "the session cookie does not reveal what the session holds", %{conn: conn} do
    code = "plaintext-recovery-code"

    conn =
      conn
      |> bypass_through(IthibatiEmailWeb.Router, :browser)
      |> get(~p"/")
      |> put_session(:recovery_codes, [code])
      |> send_resp(200, "")

    %{value: cookie} = conn.resp_cookies["_ithibati_email_key"]

    refute cookie |> String.split(".") |> Enum.any?(&reveals?(&1, code))
  end

  defp reveals?(part, secret) do
    case Base.url_decode64(part, padding: false) do
      {:ok, decoded} -> String.contains?(decoded, secret)
      :error -> false
    end
  end
end
