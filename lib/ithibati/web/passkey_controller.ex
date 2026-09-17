# The sentinel for the web half; `Ithibati.Web.Handler` says why it is this one.
if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.PasskeyController do
    @moduledoc """
    Handles the JSON endpoints mounted by `Ithibati.Web.Router`.

    Registration and authentication each use a challenge request followed by verification.
    Challenges occupy separate session entries, and each carries its mount settings. Registration
    also retains the subject approved by `c:Ithibati.Web.Handler.registration_subject/2`.
    Verification removes the corresponding entry from the connection's session before checking it.

    Separate entries prevent an authentication challenge from being used to bypass registration
    approval. Matching the mount settings prevents a challenge from being completed through a
    different handler or ceremony configuration.

    Recovery redeems a code in one request without a WebAuthn challenge. Successful verification
    or redemption delegates to the application's `Ithibati.Web.Handler`. Atom error reasons become
    JSON strings with status `422`; other reasons become `verification_failed`.
    """
    use Phoenix.Controller, formats: [:json]

    alias Ithibati.Identity.Passkeys
    alias Ithibati.Identity.RecoveryCodes

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

    # Remove the challenge from the connection session before verification so returned failures
    # also carry the session change.
    defp spend(conn, key), do: {delete_session(conn, key), get_session(conn, key)}

    # Bind the stored challenge to its mount settings. Otherwise a different handler or policy
    # could complete a challenge approved here. Shared slots keep the session bounded; a new
    # challenge for the same ceremony replaces the previous one.
    defp keep(conn, key, held), do: put_session(conn, key, {settings(conn), held})

    # Recovery spends a bearer code directly; it does not require a WebAuthn challenge.
    def recovery(conn, %{"code" => code}) when is_binary(code) do
      with {:ok, account, fresh} <- RecoveryCodes.redeem(code),
           {:ok, conn} <- handler(conn).recovered(conn, account, fresh) do
        answered(conn, "recovered")
      else
        # Use the same public refusal for unknown and spent recovery codes.
        {:error, :invalid} -> refuse(conn, :invalid_code)
        {:error, reason} -> refuse(conn, reason)
      end
    end

    # Handle malformed input separately. A catch-all on the callback result would hide handler
    # contract errors after the code had already been spent.
    def recovery(conn, _params), do: refuse(conn, :invalid_code)

    defp taken({settings, held}, settings), do: {:ok, held}
    defp taken(_held, _settings), do: {:error, :no_challenge}

    defp settings(conn), do: conn.private.ithibati
    defp handler(conn), do: settings(conn).handler

    # Preserve handler responses. The hook expects JSON; navigation uses a JSON `redirect`
    # field because an HTTP redirect would be followed by fetch rather than by the page.
    defp answered(%{state: :sent} = conn, _status), do: conn
    defp answered(conn, status), do: json(conn, %{status: status})

    # Use the configured public URL rather than the node's connection scheme and port, which
    # may describe the proxy-facing HTTP connection. The handler may select other trusted origins.
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

    # Reasons may be exception structs or other terms without `String.Chars`. Only non-nil atoms
    # become public codes; all other reasons use the verification fallback.
    defp refuse(conn, reason) when is_atom(reason) and not is_nil(reason) do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: to_string(reason)})
    end

    defp refuse(conn, _reason), do: refuse(conn, :verification_failed)
  end
end
