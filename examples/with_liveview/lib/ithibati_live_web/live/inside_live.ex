defmodule IthibatiLiveWeb.InsideLive do
  @moduledoc """
  Behind `{:require_account, to: "/"}`. Nothing here checks anything: by the time `mount/3` runs,
  the gate has either assigned an account or sent the visitor away.
  """
  use IthibatiLiveWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-2xl font-semibold">Inside</h1>
      <p>Only {@current_account.email} sees this.</p>
      <p>
        <.link navigate={~p"/"} class="underline">Back</.link> —
        what this account may <em>do</em> is this application's question, not the library's.
      </p>
    </div>
    """
  end
end
