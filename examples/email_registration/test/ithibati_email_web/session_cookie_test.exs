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
end
