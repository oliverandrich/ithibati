if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.GateTest do
    @moduledoc """
    The rule this file exists for: a gate that lists its known modes and lets anything else through
    turns a typo into a page that refuses nobody. It looks like protection, is none, and never
    fails visibly — so the last clause refuses and an unknown mode raises.

    Driven through the endpoint's pipeline rather than by calling the plug, because a mode that
    works only when somebody else fetched the session first passes a direct call and fails a real
    request.
    """
    use Ithibati.DataCase, async: true

    import Phoenix.ConnTest

    alias Ithibati.Identity.Tokens
    alias Ithibati.Web.Gate

    @endpoint Ithibati.TestEndpoint

    setup do
      %{account: user_fixture()}
    end

    describe "the modes it has" do
      test "current_account assigns nobody when there is no session" do
        response = build_conn() |> get("/open") |> json_response(200)

        assert response == %{"account_id" => nil}
      end

      test "current_account assigns the account a session names", ctx do
        response = recycle(signed_in(ctx.account)) |> get("/open") |> json_response(200)

        assert response == %{"account_id" => to_string(ctx.account.id)}
      end

      test "require_account sends a stranger where the mount said" do
        conn = build_conn() |> get("/closed")

        assert redirected_to(conn) == "/sign-in"
      end

      test "require_account without somewhere to go answers 401" do
        conn = build_conn() |> get("/api")

        assert conn.status == 401
      end

      test "require_account lets an account through", ctx do
        response = recycle(signed_in(ctx.account)) |> get("/closed") |> json_response(200)

        assert response == %{"account_id" => to_string(ctx.account.id)}
      end
    end

    # The reason the two halves live in one module: a LiveView that disagreed with the connection it
    # mounted from would let somebody through one door and not the other, and the mismatch shows up
    # as a page that behaves differently after a refresh.
    describe "the same session, read from a LiveView" do
      test "current_account assigns whoever the session names", ctx do
        token = Tokens.generate_session_token(ctx.account)

        assert {:cont, socket} = Gate.on_mount(:current_account, %{}, session(token), socket())
        assert socket.assigns.current_account.id == ctx.account.id
      end

      test "current_account assigns nobody when the session names nobody" do
        assert {:cont, socket} = Gate.on_mount(:current_account, %{}, %{}, socket())
        assert socket.assigns.current_account == nil
      end

      test "require_account halts a stranger" do
        mode = {:require_account, to: "/sign-in"}

        assert {:halt, socket} = Gate.on_mount(mode, %{}, %{}, socket())
        assert socket.redirected == {:redirect, %{to: "/sign-in", status: 302}}
      end

      test "require_account lets an account through", ctx do
        mode = {:require_account, to: "/sign-in"}
        token = Tokens.generate_session_token(ctx.account)

        assert {:cont, _socket} = Gate.on_mount(mode, %{}, session(token), socket())
      end

      # Without it a halt sends nobody anywhere, which in a LiveView is a blank page rather than a
      # refusal — so it is asked for where the mount is written, not discovered at the first visit.
      test "require_account without somewhere to go refuses to be written that way" do
        assert_raise ArgumentError, ~r/nowhere to send/, fn ->
          Gate.on_mount(:require_account, %{}, %{}, socket())
        end
      end

      # The one that matters: checked only on the anonymous path, a missing `:to` would mount
      # perfectly for everybody who is signed in and blow up in front of the first stranger.
      test "and refuses it for a visitor who is signed in, too", ctx do
        token = Tokens.generate_session_token(ctx.account)

        assert_raise ArgumentError, ~r/nowhere to send/, fn ->
          Gate.on_mount(:require_account, %{}, session(token), socket())
        end
      end
    end

    describe "the modes it does not have" do
      # The whole reason for this module. A permissive last clause would answer `{:cont, socket}`
      # here and the page would be served to anybody.
      # Built rather than written out: the raising clause narrows what the compiler believes these
      # functions accept, so a literal typo here is reported as a type error on every run — which
      # is the compiler agreeing with the test and shouting about it.
      test "a made-up mode raises rather than continuing" do
        made_up = String.to_atom("requires_account")

        assert_raise ArgumentError, ~r/current_account/, fn ->
          Gate.on_mount(made_up, %{}, %{}, socket())
        end
      end

      # The same rule one level down. A typo here is the silent half: the mode is real, so nothing
      # refuses it, and every stranger gets a bare 401 where a redirect was written.
      test "an option nobody has heard of is refused as well" do
        assert_raise ArgumentError, ~r/:to/, fn ->
          Gate.init({:require_account, too: "/sign-in"})
        end
      end

      test "and so does a made-up mode on the plug" do
        made_up = String.to_atom("requrie_account")

        assert_raise ArgumentError, ~r/current_account/, fn ->
          Gate.init(made_up)
        end
      end
    end

    describe "the session it offers" do
      # A signed-out session that still opens doors is the sign-out counterpart of a replayed
      # assertion, and it fails just as quietly.
      test "log_out revokes the token, so a cookie kept from before is worthless", ctx do
        response = signed_in(ctx.account)
        assert recycle(response) |> get("/open") |> json_response(200) != %{"account_id" => nil}

        recycle(response) |> get("/session/out")

        # The same cookie as before, which is all an attacker who copied it ever has. Clearing the
        # session on the client would leave this working, and nothing would say so.
        assert recycle(response) |> get("/open") |> json_response(200) == %{"account_id" => nil}
      end

      # Both halves, and the second is the one that matters: clearing the contents is not renewing
      # the id, and a session id handed to somebody before they sign in is one an attacker already
      # holds afterwards. Asserting only on the contents leaves `configure_session(renew: true)`
      # free to be deleted with the suite still green.
      test "log_in clears the session and renews its id", ctx do
        before = build_conn() |> Plug.Test.init_test_session(%{decoy: "kept?"})
        signed_in = Gate.log_in(before, ctx.account)

        assert Plug.Conn.get_session(signed_in, :decoy) == nil
        assert signed_in.private[:plug_session_info] == :renew
      end
    end

    # The *response*, not a request built from it: recycling it gives a fresh connection carrying the
    # session cookie, and it can be recycled more than once — which is what a stolen cookie is.
    defp signed_in(account), do: build_conn() |> get("/session/#{account.id}")

    defp socket, do: %Phoenix.LiveView.Socket{}

    # The key written out rather than read off the module: what a LiveView receives is the session
    # map, and the string form of this library's key is the contract a consumer's `live_session`
    # depends on — a test that derived it from the attribute would follow a rename that broke them.
    defp session(token), do: %{Gate.session_key() => token}
  end
end
