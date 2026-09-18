defmodule IthibatiEmailWeb.InsideLive do
  @moduledoc "The authenticated page, reached only after completing registration or sign-in."
  use IthibatiEmailWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>Inside</.header>
      <p>Signed in as {@current_account.email}.</p>
      <.link href={~p"/session"} method="delete" class="link">sign out</.link>
    </Layouts.app>
    """
  end
end
