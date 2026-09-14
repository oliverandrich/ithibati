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
        before =
          Ithibati.TestEndpoint
          |> build_conn_with_endpoint()
          |> Plug.Conn.put_session(:decoy, "kept?")

        signed_in = Gate.log_in(before, ctx.account)

        assert Plug.Conn.get_session(signed_in, :decoy) == nil
        assert signed_in.private[:plug_session_info] == :renew
      end
    end

    # The half a revoked token does not reach: a LiveView that is already connected holds its
    # account in assigns and keeps accepting events, because nothing re-reads the session until the
    # socket reconnects. Phoenix answers this with a topic named in the session and a `"disconnect"`
    # broadcast on it; `docs/design.md` decision 11 says why this library sends that itself.
    describe "the sockets a session opened" do
      test "log_in names the live socket, so something can be said to it later", ctx do
        signed_in = Gate.log_in(build_conn_with_endpoint(Ithibati.TestEndpoint), ctx.account)

        token = Plug.Conn.get_session(signed_in, Gate.session_key())

        # The key is Phoenix's, not this library's — `Phoenix.LiveView.Socket.id/1` reads exactly
        # this string — so it is written out rather than derived from anything here.
        assert Plug.Conn.get_session(signed_in, "live_socket_id") == Gate.live_socket_id(token)
      end

      # Per token rather than per account: the same person signed in on a phone is a different
      # session, and signing out here must not reach it.
      test "the topic is a different one for every session of the same account", ctx do
        one = Tokens.generate_session_token(ctx.account)
        two = Tokens.generate_session_token(ctx.account)

        refute Gate.live_socket_id(one) == Gate.live_socket_id(two)
      end

      # The token is a live credential. Topics reach logs and telemetry, so what goes in one is the
      # digest — `phx.gen.auth` puts the token itself there and this library deliberately does not.
      test "and carries no part of the token that opens anything", ctx do
        token = Tokens.generate_session_token(ctx.account)

        # The token first, because `Secrets.token/0` already answers base64url *text* — encoding it
        # again produces a string it can never appear in, so the encoded forms alone let the
        # simplest regression of all, putting the token straight into the topic, go unnoticed.
        refute Gate.live_socket_id(token) =~ token
        refute Gate.live_socket_id(token) =~ Base.url_encode64(token, padding: false)
      end

      test "log_out tells that socket to go away", ctx do
        response = signed_in(ctx.account)
        topic = Plug.Conn.get_session(response, "live_socket_id")
        assert topic

        Ithibati.TestEndpoint.subscribe(topic)

        recycle(response) |> get("/session/out")

        assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
      end

      # The consumer the guard exists for. A `live_socket_id` in an application with no pubsub
      # server would not merely fail to disconnect: `Phoenix.Socket` subscribes to that id when a
      # socket connects, through the same call that raises, so every websocket would die at init.
      # Writing nothing leaves such an application exactly where it was.
      test "an application without a pubsub server is left alone, not broken", ctx do
        conn = build_conn_with_endpoint(Ithibati.TestEndpointWithoutPubSub)
        signed_in = Gate.log_in(conn, ctx.account)

        assert Plug.Conn.get_session(signed_in, Gate.session_key())
        refute Plug.Conn.get_session(signed_in, "live_socket_id")

        # Nothing was named, so nothing is said: this is the *write* being skipped. That signing
        # out stays quiet when a socket id is present anyway is the next test's job.
        assert Gate.log_out(signed_in)
      end

      # The write and the broadcast are guarded on the same condition, but they do not happen in the
      # same *release*: a session cookie outlives a deploy. An application that drops or renames its
      # `:pubsub_server` still has cookies carrying the key, and every one of those sign-outs would
      # raise if the broadcast trusted the write.
      test "a cookie from before the pubsub server went away still signs out", ctx do
        conn =
          Ithibati.TestEndpointWithoutPubSub
          |> build_conn_with_endpoint()
          |> Plug.Conn.put_session(Gate.session_key(), Tokens.generate_session_token(ctx.account))
          |> Plug.Conn.put_session("live_socket_id", "ithibati_sessions:left-over")

        assert Gate.log_out(conn)
      end
    end

    # The *response*, not a request built from it: recycling it gives a fresh connection carrying the
    # session cookie, and it can be recycled more than once — which is what a stolen cookie is.
    defp signed_in(account), do: build_conn() |> get("/session/#{account.id}")

    # `log_in/2` now asks the connection which endpoint it belongs to, which a bare `build_conn/0`
    # does not say — only a request through one sets it.
    defp build_conn_with_endpoint(endpoint) do
      build_conn()
      |> Plug.Conn.put_private(:phoenix_endpoint, endpoint)
      |> Plug.Test.init_test_session(%{})
    end

    defp socket, do: %Phoenix.LiveView.Socket{}

    # The key written out rather than read off the module: what a LiveView receives is the session
    # map, and the string form of this library's key is the contract a consumer's `live_session`
    # depends on — a test that derived it from the attribute would follow a rename that broke them.
    defp session(token), do: %{Gate.session_key() => token}
  end
end
