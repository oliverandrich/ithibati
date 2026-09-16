# The sentinel for the web half; `Ithibati.Web.Handler` says why it is this one.
if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.Gate do
    @moduledoc """
    Who is signed in, on a connection and in a LiveView, from one place.

        pipeline :browser do
          plug :fetch_session
          plug Ithibati.Web.Gate, :current_account
        end

        live_session :admin, on_mount: [{Ithibati.Web.Gate, {:require_account, to: ~p"/sign-in"}}] do
          live "/admin", AdminLive
        end

    The gate has two modes and no others. `:current_account` assigns whoever the session names, or
    `nil`, and always continues. `:require_account` refuses when there is nobody.

    An unrecognised mode raises instead of being ignored. The plug raises from `init/1`, which
    Phoenix runs at compile time under `init_mode: :compile` and at the first request otherwise;
    the `on_mount` raises at the mount either way. A gate that listed its modes and let anything
    else through would turn a typo into a page that refuses nobody, and nothing would report
    it.

    The gate covers authentication and stops there. What an account may *do* is the
    application's, and Ithibati has no opinion about it.
    """
    import Plug.Conn
    import Phoenix.Controller, only: [redirect: 2]

    alias Ithibati.Identity.Secrets
    alias Ithibati.Identity.Sessions

    @session "ithibati_account_token"

    # Phoenix's name, not this library's: `Phoenix.LiveView.Socket.id/1` reads exactly this key out
    # of the cookie session, so it cannot be namespaced and a consumer's own use of it would
    # collide. Written out rather than derived, because the string is the contract.
    @live_socket "live_socket_id"
    @modes [:current_account, :require_account]
    @options [:to]

    @doc "The session key Ithibati stores its token under."
    def session_key, do: @session

    @doc """
    Signs an account in by storing a session token under Ithibati's session key.

    Ithibati offers this instead of imposing it. An application decides in `Ithibati.Web.Handler`
    what a verified assertion is worth, and one that issues a bearer token for an extension instead
    simply never calls this. The gate then finds nothing, which is the right answer. But a gate
    that read a key nothing here ever wrote would leave every application guessing the convention.

    `log_in/2` renews the session first, because a fixed session id handed to someone before they
    sign in is a session an attacker already holds afterwards. Renewing clears the CSRF token along
    with everything else, so **a sign-in has to end in a full page load**. The hook does that when
    a handler answers with `%{redirect: …}`. A page that stays put after signing in holds a token
    the new session has never heard of, and its next form post is refused.
    """
    def log_in(conn, account) do
      token = Sessions.generate_session_token(account)

      conn
      |> renew_session()
      |> put_session(@session, token)
      |> name_live_socket(token)
    end

    @doc """
    The topic the sockets of one session answer on.

    Ithibati derives the topic from the token's *digest*. A topic reaches logs, telemetry and
    everything subscribed to the pubsub server, and `phx.gen.auth` puts the live token itself in
    there. The topic is per token, not per account, so signing out in one browser leaves the
    same person's other devices alone.

    This function is public for an application that ends a session somewhere other than
    `log_out/1` and holds the raw token while doing it. It cannot serve "sign out my other
    devices": that starts from what the database has, which is digests.
    """
    def live_socket_id(token) when is_binary(token) do
      "ithibati_sessions:" <> Secrets.url64(Secrets.digest(token))
    end

    # Only where the endpoint can carry it, and the guard is on the *write* rather than on the
    # broadcast for a reason worth knowing: `Phoenix.Socket` subscribes to this id when a socket
    # connects, through the same call that raises without a `:pubsub_server`. An id written into an
    # application that has none would take down every websocket at connect, not just the sign-out.
    defp name_live_socket(conn, token) do
      if pubsub_endpoint(conn),
        do: put_session(conn, @live_socket, live_socket_id(token)),
        else: conn
    end

    @doc """
    Signs out and revokes the token instead of merely forgetting it.

    A session dropped on the client alone leaves a token that still resolves. That is the sign-out
    counterpart of a replayed assertion, and it fails just as quietly.
    """
    def log_out(conn) do
      conn |> get_session(@session) |> Sessions.delete_session_token()
      disconnect_live_sockets(conn)

      renew_session(conn)
    end

    # Before the session is renewed, because renewing is what takes the topic away. Both halves ask
    # the same question, but not in the same release: a cookie outlives a deploy that dropped the
    # pubsub server, so the endpoint is checked here too rather than inferred from the key existing.
    defp disconnect_live_sockets(conn) do
      with topic when is_binary(topic) <- get_session(conn, @live_socket),
           endpoint when not is_nil(endpoint) <- pubsub_endpoint(conn) do
        endpoint.broadcast(topic, "disconnect", %{})
      end
    end

    # The endpoint, when it is one that can carry a broadcast. `nil` for an application that
    # configured no server, and for a connection that never went through an endpoint at all — a plug
    # called directly in a test, say. The server's *name* is never wanted, only whether there is one.
    defp pubsub_endpoint(conn) do
      endpoint = conn.private[:phoenix_endpoint]

      if endpoint && endpoint.config(:pubsub_server), do: endpoint
    end

    # Both halves, and either alone reads like the whole thing: renewing carries the contents over
    # to the new id, and clearing leaves the id an attacker may already hold. Signing in and signing
    # out want the same pair, so they ask for it by name rather than each writing it out.
    defp renew_session(conn), do: conn |> configure_session(renew: true) |> clear_session()

    @doc false
    def init(mode), do: mode!(mode)

    # Already normalised: Phoenix runs `init/1` at compile time and hands the result here, so
    # validating again would pay per request for an answer that cannot have changed — and would
    # give the option check below two homes.
    @doc false
    def call(conn, {mode, opts}) do
      account = Sessions.get_user_by_session_token(get_session(conn, @session))
      conn = assign(conn, :current_account, account)

      case {mode, account} do
        {:current_account, _account} -> conn
        {:require_account, nil} -> refuse(conn, opts)
        {:require_account, _account} -> conn
      end
    end

    @doc """
    The same two modes, for LiveView.

    `:require_account` takes `:to` here and has no default. A LiveView that halts with nowhere to
    send a person is a dead end, and the path belongs to the application.
    """
    def on_mount(mode, _params, session, socket) do
      {mode, opts} = mode!(mode)
      # Before the branch, not inside it: asked for only on the anonymous path, a missing `:to`
      # would mount perfectly for everyone who is signed in and raise at the first stranger — a
      # 500 exactly where a redirect was meant, and only in front of the person it was meant for.
      to = if mode == :require_account, do: to!(opts)

      # `assign_new` rather than `assign`, and it earns both halves: on the first, disconnected
      # render LiveView seeds it from `conn.assigns`, so the plug's lookup is not repeated, and a
      # LiveView nested under one that already answered inherits instead of asking again.
      socket =
        Phoenix.Component.assign_new(socket, :current_account, fn ->
          Sessions.get_user_by_session_token(session[@session])
        end)

      case {mode, socket.assigns.current_account} do
        {:current_account, _account} ->
          {:cont, socket}

        {:require_account, nil} ->
          {:halt, Phoenix.LiveView.redirect(socket, to: to)}

        {:require_account, _account} ->
          {:cont, socket}
      end
    end

    defp to!(opts) do
      Keyword.get(opts, :to) ||
        raise ArgumentError,
              "on_mount {Ithibati.Web.Gate, {:require_account, to: \"/sign-in\"}} — a LiveView " <>
                "that halts with nowhere to send a person is a dead end, and this library does " <>
                "not own your paths."
    end

    # Raised rather than returned, and raised from `init/1` so a router says so at compile time:
    # the alternative is a mode nobody recognises behaving like the most permissive one.
    defp mode!(mode) when mode in @modes, do: {mode, []}

    # The option list gets what the mode list gets, and for the same reason one level down: `too:`
    # instead of `to:` would otherwise answer every stranger a bare 401 where a redirect to the
    # sign-in page was written, and nothing would say so. The plug is the half where that is
    # silent — `on_mount` already raises on the same typo.
    defp mode!({mode, opts}) when mode in @modes and is_list(opts) do
      unknown = if Keyword.keyword?(opts), do: Keyword.keys(opts) -- @options, else: opts

      if unknown == [] do
        {mode, opts}
      else
        raise ArgumentError,
              "#{inspect(unknown)} is not an option this gate has; it has " <>
                Enum.map_join(@options, " and ", &inspect/1)
      end
    end

    defp mode!(other) do
      raise ArgumentError,
            "#{inspect(other)} is not a mode this gate has; it has " <>
              "#{Enum.map_join(@modes, " and ", &inspect/1)}"
    end

    defp refuse(conn, opts) do
      conn =
        case Keyword.get(opts, :to) do
          nil -> send_resp(conn, 401, "")
          path -> redirect(conn, to: path)
        end

      halt(conn)
    end
  end
end
