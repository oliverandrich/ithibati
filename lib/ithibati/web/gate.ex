# The sentinel for the web half; `Ithibati.Web.Handler` says why it is this one.
if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.Gate do
    @moduledoc """
    Loads the current account from a session and optionally requires authentication.

    Use it as a plug after `fetch_session`, and as an `on_mount` hook for LiveViews:

        pipeline :browser do
          plug :fetch_session
          plug Ithibati.Web.Gate, :current_account
        end

        live_session :members,
          on_mount: [{Ithibati.Web.Gate, {:require_account, to: "/sign-in"}}] do
          live "/inside", InsideLive
        end

    Both forms assign `:current_account` to the account or `nil`.

      * `:current_account` always continues.
      * `:require_account` refuses unauthenticated access. The plug redirects when given `to:`
        and otherwise sends `401`. The LiveView hook requires `to:` and redirects there.

    Unknown modes and options raise `ArgumentError`. The gate reads session tokens only;
    application permissions and bearer-token authentication remain application concerns.
    """
    import Plug.Conn
    import Phoenix.Controller, only: [redirect: 2]

    alias Ithibati.Config
    alias Ithibati.Identity.Secrets
    alias Ithibati.Identity.Sessions

    @session "ithibati_account_token"

    # LiveView reads this exact session key to subscribe to disconnect broadcasts.
    @live_socket "live_socket_id"
    @modes [:current_account, :require_account]
    @options [:to]

    @doc "The session key Ithibati stores its token under."
    def session_key, do: @session

    @doc """
    Creates a session token, renews and clears the browser session, and returns the connection.

    `account` must belong to the configured account schema and exist in the database. The new
    token is stored under `session_key/0`. Existing session contents are cleared; retain anything
    the next page needs only after this call.

    When the connection's endpoint has a PubSub server, the session also receives the
    `live_socket_id` used to disconnect this session's LiveViews on logout.

    Complete sign-in with a full page load to refresh the CSRF token. The shipped browser hook
    does this for a JSON response containing `%{redirect: path}`.

    This call does not revoke the account's other session rows.
    """
    def log_in(conn, account) do
      token = Sessions.generate_session_token(account)

      conn
      |> renew_session()
      |> put_session(@session, token)
      |> name_live_socket(token)
    end

    @doc """
    Returns the LiveView disconnect topic derived from a plaintext session token.

    The topic contains a URL-safe encoding of the token's digest, so it does not expose the
    plaintext token to PubSub subscribers or logs. It identifies one session, not every session
    belonging to an account.

    Use this when implementing a separate revocation path that holds the plaintext token and
    needs to broadcast `"disconnect"`. Do not pass the digest stored in the database; it would
    be hashed again and produce a different topic.
    """
    def live_socket_id(token) when is_binary(token) do
      socket_topic(Secrets.digest(token))
    end

    # Only name a socket when the endpoint has PubSub. Otherwise socket subscription would
    # fail during connection, before logout is ever attempted.
    defp name_live_socket(conn, token) do
      if pubsub_endpoint(conn),
        do: put_session(conn, @live_socket, live_socket_id(token)),
        else: conn
    end

    @doc """
    Revokes the current session token, renews and clears the browser session, and returns the connection.

    When the session has a live-socket topic and the endpoint has a PubSub server, this also
    broadcasts `"disconnect"` to that topic. LiveView sockets must receive session information
    through `connect_info` to subscribe to it. Without that setup, revocation affects subsequent
    session lookups but does not disconnect existing sockets.

    A missing token is harmless. Other sessions belonging to the account are unaffected.
    """
    def log_out(conn) do
      conn |> get_session(@session) |> Sessions.delete_session_token()
      disconnect_live_sockets(conn)

      renew_session(conn)
    end

    @doc """
    Revokes all sessions of the currently authenticated account and clears the browser session.

    Resolves the account from the current token, not from connection assigns. Missing, unknown
    or expired tokens only clear this browser's session. With endpoint PubSub configured,
    broadcasts `"disconnect"` to every revoked session's LiveView topic after the database commits.
    Sockets must receive the session through `connect_info`, as for `log_out/1`.

    Call outside a database transaction; an outer transaction raises `ArgumentError` before any
    revocation so notifications cannot precede commit. Database errors propagate without retries.
    PubSub delivery is not atomic with the database commit: a delivery failure does not restore
    revoked sessions. Accounts may sign in again, and concurrent new sessions may survive.
    """
    def log_out_all(conn) do
      if Config.repo().in_transaction?() do
        raise ArgumentError, "call log_out_all outside a database transaction"
      end

      with account when not is_nil(account) <-
             Sessions.get_user_by_session_token(get_session(conn, @session)) do
        digests = Sessions.revoke_all(account)

        if endpoint = pubsub_endpoint(conn) do
          Enum.each(digests, &endpoint.broadcast(socket_topic(&1), "disconnect", %{}))
        end
      end

      renew_session(conn)
    end

    defp socket_topic(digest), do: "ithibati_sessions:" <> Secrets.url64(digest)

    # Read the topic before clearing the session. Recheck PubSub because cookies can survive
    # a deployment that removes the endpoint's PubSub configuration.
    defp disconnect_live_sockets(conn) do
      with topic when is_binary(topic) <- get_session(conn, @live_socket),
           endpoint when not is_nil(endpoint) <- pubsub_endpoint(conn) do
        endpoint.broadcast(topic, "disconnect", %{})
      end
    end

    # Direct Plug calls may have no endpoint; endpoints without PubSub cannot broadcast.
    defp pubsub_endpoint(conn) do
      endpoint = conn.private[:phoenix_endpoint]

      if endpoint && endpoint.config(:pubsub_server), do: endpoint
    end

    # Renew the session ID and clear its contents together to avoid carrying either across login.
    defp renew_session(conn), do: conn |> configure_session(renew: true) |> clear_session()

    @doc false
    def init(mode), do: mode!(mode)

    # `init/1` has already validated and normalized these options.
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
    Loads `:current_account` during a LiveView mount and enforces the selected mode.

    Returns `{:cont, socket}` in `:current_account` mode and for authenticated mounts in
    `:require_account` mode. An unauthenticated required mount returns `{:halt, socket}` with a
    redirect to the required `:to` path.

    A missing `:to`, unknown mode or unknown option raises `ArgumentError`. Account assignment
    uses `assign_new/3` so an account already loaded by the plug or parent LiveView can be reused.
    """
    def on_mount(mode, _params, session, socket) do
      {mode, opts} = mode!(mode)
      # Validate the redirect even for signed-in visitors so a missing option does not remain
      # hidden until the first unauthenticated mount.
      to = if mode == :require_account, do: to!(opts)

      # Reuse the plug or parent LiveView assignment to avoid repeating its account lookup.
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

    # Reject unknown modes instead of silently allowing access.
    defp mode!(mode) when mode in @modes, do: {mode, []}

    # Reject misspelled options so `too:` cannot silently replace an intended redirect with a 401.
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
