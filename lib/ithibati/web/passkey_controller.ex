if Code.ensure_loaded?(Phoenix.Controller) do
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
          |> put_session(@registration, {challenge, subject})
          |> json(Passkeys.registration_options(challenge, subject, rp_name: rp_name))

        {:error, reason} ->
          refuse(conn, reason)
      end
    end

    def registration(conn, params) do
      {conn, held} = spend(conn, @registration)

      with {:ok, {challenge, subject}} <- taken(held),
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
          |> put_session(@authentication, challenge)
          |> json(Passkeys.authentication_options(challenge))

        {:error, reason} ->
          refuse(conn, reason)
      end
    end

    def authentication(conn, params) do
      {conn, held} = spend(conn, @authentication)

      with {:ok, challenge} <- taken(held),
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

    defp taken(nil), do: {:error, :no_challenge}
    defp taken(held), do: {:ok, held}

    defp settings(conn), do: conn.private.ithibati
    defp handler(conn), do: settings(conn).handler

    # A handler that answered for itself keeps its answer — a redirect to the page that shows the
    # recovery codes, say. Only a handler that merely changed the connection gets this library's
    # word for what happened, which the client treats as "nothing further to do".
    defp answered(%{state: :sent} = conn, _status), do: conn
    defp answered(conn, status), do: json(conn, %{status: status})

    # From the endpoint's configured URL, not from `conn.scheme`/`conn.port`, which describe the
    # connection this node accepted: behind a proxy that terminates TLS those say `http` while the
    # browser signed `https`, and every ceremony would fail on an origin mismatch in production and
    # nowhere else. The configured URL is also what settles `www.example.com` against
    # `example.com`, which an authenticator treats as two unrelated relying parties.
    defp relying_party(conn) do
      url = endpoint_module(conn).struct_url()

      {url.host, URI.to_string(url)}
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
