defmodule IthibatiEmailWeb.InviteLive do
  @moduledoc """
  What somebody sees when they open an invitation link.

  The page shows the email address the invitation was addressed to and does not offer to change it. That
  is not politeness: `Ithibati.Identity.Invitations.accept/2` checks that the account being created
  carries the identifier the invitation named, so a field here would only produce a refusal further
  down — and, until somebody noticed, a form that looks like it hands an invitation to whoever fills
  it in.
  """
  use IthibatiEmailWeb, :live_view

  alias Ithibati.Identity.Invitations
  alias IthibatiEmailWeb.CeremonyMessages

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok, assign(socket, token: token, invitation: Invitations.fetch(token), error: nil)}
  end

  @impl true
  def handle_event("accept", _params, socket) do
    {:noreply, push_event(socket, "ithibati:register", %{token: socket.assigns.token})}
  end

  def handle_event("ithibati:failed", %{"error" => error} = payload, socket) do
    {:noreply, assign(socket, error: CeremonyMessages.message(error, payload["exception"]))}
  end

  def handle_event("ithibati:done", _payload, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        You have been invited
        <:subtitle :if={@invitation}>
          The account will be called <strong>{@invitation.email}</strong>.
        </:subtitle>
      </.header>

      <div :if={is_nil(@invitation)} class="alert alert-error mt-6">
        <span>
          This invitation has been used already, or it has expired. A token nobody holds is
          answered the same way, deliberately.
        </span>
      </div>

      <div :if={@error} class="alert alert-error mt-6"><span>{@error}</span></div>

      <p :if={@invitation} class="mt-6">
        <.button phx-click="accept" variant="primary">Accept with a passkey</.button>
      </p>

      <Layouts.passkey_ceremony />
    </Layouts.app>
    """
  end
end
