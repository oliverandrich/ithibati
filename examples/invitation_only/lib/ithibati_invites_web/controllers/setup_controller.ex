defmodule IthibatiInvitesWeb.SetupController do
  @moduledoc "Exchanges the operator code for short-lived first-claim authorization."
  use IthibatiInvitesWeb, :controller

  alias Ithibati.Identity.Instance

  def authorize(conn, %{"setup_code" => code}) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    if Instance.needs_setup?() do
      case Instance.authorize_code(code) do
        {:ok, proof} ->
          conn
          |> put_session(:initial_claim_authorization, proof)
          |> redirect(to: ~p"/")

        {:error, :invalid_setup_code} ->
          conn
          |> put_flash(:error, "That operator code is invalid or has been replaced.")
          |> redirect(to: ~p"/")

        # This instance sets `initial_claim: :operator_code`, so it cannot arrive — but the
        # answer exists, and an example that ignored it would teach an incomplete `case`.
        {:error, :claim_is_open} ->
          conn
          |> put_flash(:error, "This instance does not ask for an operator code.")
          |> redirect(to: ~p"/")
      end
    else
      redirect(conn, to: ~p"/")
    end
  end

  def authorize(conn, _params), do: authorize(conn, %{"setup_code" => ""})
end
