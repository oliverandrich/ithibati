defmodule IthibatiOpenWeb.InsideLive do
  @moduledoc """
  Behind `{:require_account, to: "/"}`. Nothing here checks anything: by the time `mount/3` runs,
  the gate has either assigned an account or sent the visitor away.
  """
  use IthibatiOpenWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Inside
        <:subtitle>Only {@current_account.username} sees this.</:subtitle>
      </.header>

      <p class="mt-6">
        <.link navigate={~p"/"} class="link">Back</.link> — what this account may <em>do</em> is
        this application's question, not the library's.
      </p>
    </Layouts.app>
    """
  end
end
