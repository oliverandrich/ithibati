defmodule IthibatiEmailWeb.SessionController do
  @moduledoc "Signing out is a plain request, because a LiveView cannot clear a session cookie."
  use IthibatiEmailWeb, :controller

  alias Ithibati.Web.Gate

  def sign_out(conn, _params), do: conn |> Gate.log_out() |> redirect(to: "/")

  @doc """
  The recovery codes, shown once.

  A controller and not a LiveView, because the session key has to be gone after this: a LiveView
  has no connection to delete it from, so a refresh would show them again — and the whole point of
  "shown once" is that a second look is not available.
  """
  def recovery_codes(conn, _params) do
    case get_session(conn, :recovery_codes) do
      nil -> redirect(conn, to: "/")
      codes -> conn |> delete_session(:recovery_codes) |> render(:recovery_codes, codes: codes)
    end
  end
end
