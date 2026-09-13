defmodule IthibatiOpenWeb.CeremonyTest do
  @moduledoc """
  The pipeline this example and the library's README both insist on, driven rather than described.

  Both halves have been wrong here before. The routes went through `:browser` at first, whose
  `accepts ["html"]` refused the hook's request with a 406 before the controller was reached; and
  the README stated the 403 below without anything proving it.
  """
  use IthibatiOpenWeb.ConnCase

  defp signed_conn do
    conn = get(build_conn(), "/")
    [_, token] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

    {recycle(conn), token}
  end

  test "a ceremony route answers JSON to the request the hook actually makes" do
    {conn, token} = signed_conn()

    response =
      conn
      |> put_req_header("x-csrf-token", token)
      |> put_req_header("accept", "application/json")
      |> post(~p"/auth/registration/challenge", %{"username" => "first_one"})
      |> json_response(200)

    # The shape the browser is handed, and the three parts of it this library refuses to make
    # optional: a discoverable credential, in both spellings, and the extension that reports back
    # whether the authenticator honoured the wish.
    assert %{"challenge" => _, "rp" => %{"id" => _}} = response
    assert response["authenticatorSelection"]["residentKey"] == "required"
    assert response["authenticatorSelection"]["requireResidentKey"] == true
    assert response["extensions"]["credProps"] == true
  end

  # `Plug.Test` sets `plug_skip_csrf_protection`, so every test connection is exempt by default and
  # this assertion would pass against an application with no protection at all. Turning it back on
  # is the only way the check is the thing being tested rather than the thing being skipped.
  test "and refuses the same request without a CSRF token" do
    {conn, _token} = signed_conn()

    assert_error_sent(403, fn ->
      conn
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("accept", "application/json")
      |> post(~p"/auth/registration/challenge", %{"username" => "first_one"})
    end)
  end
end
