defmodule IthibatiInvitesWeb.SignInSetupTest do
  use IthibatiInvitesWeb.ConnCase

  import Phoenix.LiveViewTest

  test "an unclaimed instance asks for the operator code before offering registration", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "setup-code-form"
    refute html =~ "Claim this instance"
  end
end
