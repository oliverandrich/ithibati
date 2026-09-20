defmodule IthibatiInvitesWeb.SetupControllerTest do
  use IthibatiInvitesWeb.ConnCase

  alias Ithibati.Identity.Instance

  test "valid operator code establishes a current session proof", %{conn: conn} do
    {:ok, code} = Instance.issue_code()
    response = post(conn, ~p"/setup-code", %{"setup_code" => code})

    assert redirected_to(response) == "/"
    assert ["no-store"] = Plug.Conn.get_resp_header(response, "cache-control")
    assert Instance.authorized?(get_session(response, :initial_claim_authorization))
  end

  test "invalid and rotated codes leave the session unauthorized", %{conn: conn} do
    {:ok, old_code} = Instance.issue_code()
    {:ok, _new_code} = Instance.issue_code()

    for code <- ["wrong", old_code] do
      response = post(conn, ~p"/setup-code", %{"setup_code" => code})
      assert redirected_to(response) == "/"
      refute get_session(response, :initial_claim_authorization)
    end
  end

  test "the setup endpoint requires CSRF protection", %{conn: conn} do
    {:ok, code} = Instance.issue_code()

    assert_error_sent(403, fn ->
      conn
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
      |> post(~p"/setup-code", %{"setup_code" => code})
    end)
  end

  test "the application filters setup codes from request logging" do
    assert Phoenix.Logger.filter_values(%{"setup_code" => "sensitive"}) ==
             %{"setup_code" => "[FILTERED]"}
  end
end
