# The sentinel for the web half; `Ithibati.Web.Handler` says why it is this one.
if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.PasskeyController do
    @moduledoc """
    The two ceremonies, four actions, as JSON.

    A challenge is minted in one request and verified in the next, so it waits in the session
    between them. It is deleted the first time a verification is attempted, whether that succeeded
    or not: a challenge is single-use, and nothing in `Ithibati.Identity.Passkeys` can hold that
    property — it lives wherever the caller put it, and a replayed assertion is indistinguishable
    from a first one there. This is the caller, so this is where it happens.

    The two ceremonies keep their challenges in separate places. `Wax` checks the type the *client*
    wrote into the client data, not the type of the challenge it verifies against, so one shared
    slot would let a challenge taken from the ungated sign-in endpoint be spent on a registration —
    and `c:Ithibati.Web.Handler.registration_subject/2` is the only place an instance can refuse
    someone.

    What follows a verification belongs to the application; see `Ithibati.Web.Handler`.
    """
    use Phoenix.Controller, formats: [:json]

    alias Ithibati.Identity.Passkeys

    @registration :ithibati_registration_challenge
    @authentication :ithibati_authentication_challenge

    def registration_challenge(conn, params) do
      case handler(conn).registration_subject(conn, params) do
        {:ok, subject} ->
          %{rp_name: rp_name, ceremony: ceremony} = settings(conn)
          {rp_id, origin} = relying_party(conn)
          challenge = Passkeys.registration_challenge(rp_id, origin, ceremony)

          conn
          |> keep(@registration, {challenge, subject})
          |> json(Passkeys.registration_options(challenge, subject, rp_name: rp_name))

        {:error, reason} ->
          refuse(conn, reason)
      end
    end

    def registration(conn, params) do
      {conn, held} = spend(conn, @registration)

      with {:ok, {challenge, subject}} <- taken(held, settings(conn)),
           {:ok, key_attrs} <- Passkeys.verify_registration(params["credential"], challenge),
           {:ok, conn} <- handler(conn).register(conn, key_attrs, subject, params) do
        answered(conn, "registered")
      else
        {:error, reason} -> refuse(conn, reason)
      end
    end

    def authentication_challenge(conn, _params) do
      {rp_id, origin} = relying_party(conn)

      case Passkeys.authentication_challenge(rp_id, origin, settings(conn).ceremony) do
        {:ok, challenge} ->
          conn
          |> keep(@authentication, challenge)
          |> json(Passkeys.authentication_options(challenge))

        {:error, reason} ->
          refuse(conn, reason)
      end
    end

    def authentication(conn, params) do
      {conn, held} = spend(conn, @authentication)

      with {:ok, challenge} <- taken(held, settings(conn)),
           {:ok, account} <- Passkeys.verify_authentication(params["credential"], challenge),
           {:ok, conn} <- handler(conn).authenticate(conn, account) do
        answered(conn, "authenticated")
      else
        {:error, reason} -> refuse(conn, reason)
      end
    end

    # Read and dropped in one step, before anything can fail: every path out of a verification
    # leaves the challenge spent, including the ones that never reach the `else`. Returned rather
    # than stashed on the connection, where a value that lives for three lines would read as part of
    # what this library puts there for others.
    defp spend(conn, key), do: {delete_session(conn, key), get_session(conn, key)}

    # The mount travels with the challenge rather than in the name of the slot it sits in. Two
    # mounts may answer to different relying parties and different handlers, and sharing one slot
    # without this let a challenge minted under one be spent at the other's verify route: the
    # assertion validates against its own challenge, so nothing refuses it, and the wrong handler
    # decides what it is worth — on the registration side carrying a subject one mount approved into
    # another mount's `register/4`, past the only place an instance can say "not you".
    #
    # Compared rather than hashed into the key, so there is no collision to reason about, the
    # session still holds two slots however many mounts an application has, and a challenge offered
    # to the wrong mount is spent there all the same.
    defp keep(conn, key, held), do: put_session(conn, key, {settings(conn), held})

    defp taken({settings, held}, settings), do: {:ok, held}
    defp taken(_held, _settings), do: {:error, :no_challenge}

    defp settings(conn), do: conn.private.ithibati
    defp handler(conn), do: settings(conn).handler

    # A handler that answered for itself keeps its answer. Answer in JSON, though — the hook reads
    # the body, and `fetch` follows a 3xx on its own, so a `Phoenix.Controller.redirect/2` here
    # arrives as an HTML page the client cannot read and the person stays where they were. To send
    # somebody somewhere, say so in the body: `json(conn, %{redirect: "/recovery-codes"})`.
    #
    # Only a handler that merely changed the connection gets this library's word for what happened,
    # which the client treats as "nothing further to do".
    defp answered(%{state: :sent} = conn, _status), do: conn
    defp answered(conn, status), do: json(conn, %{status: status})

    # The handler's answer when it has one — an extension and a native app post to these same
    # routes and their origins are not the server's, and which of them an application accepts is
    # the application's decision.
    #
    # Otherwise the endpoint's configured URL, not `conn.scheme`/`conn.port`, which describe the
    # connection this node accepted: behind a proxy that terminates TLS those say `http` while the
    # browser signed `https`, and every ceremony would fail on an origin mismatch in production and
    # nowhere else. The configured URL is also what settles `www.example.com` against
    # `example.com`, which an authenticator treats as two unrelated relying parties.
    defp relying_party(conn) do
      handler = handler(conn)
      url = endpoint_module(conn).struct_url()
      default = {url.host, URI.to_string(url)}

      if Code.ensure_loaded?(handler) and function_exported?(handler, :relying_party, 2) do
        handler.relying_party(conn, default)
      else
        default
      end
    end

    # Never `to_string/1` on the reason: `Wax` answers with exception structs, and `String.Chars`
    # is not implemented for them, so the expiring challenge — the commonest real failure there is —
    # would have crashed with a 500 on top of a spent challenge. A handler's reason is the
    # application's and may be any term at all.
    defp refuse(conn, reason) when is_atom(reason) and not is_nil(reason) do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: to_string(reason)})
    end

    defp refuse(conn, _reason), do: refuse(conn, :verification_failed)
  end
end
