defmodule IthibatiInvitesWeb.SignInLive do
  @moduledoc """
  The LiveView says *when* a ceremony starts; the hook does the round-trips.

  That split is not a style choice. A ceremony ends in a session cookie and a LiveView cannot set
  one, so the hook posts to the endpoints over `fetch` and follows the redirect the handler answers
  with. What a LiveView is good at — validating the fields before any of that begins — is what it
  does here.
  """
  use IthibatiInvitesWeb, :live_view

  alias Ithibati.Identity.Instance
  alias IthibatiInvitesWeb.CeremonyMessages

  @impl true
  def mount(_params, _session, socket) do
    # Courtesy only: `registration_subject/2` asks the same question before minting a challenge,
    # and that is the answer that counts. A request posted straight at the endpoint meets the real
    # refusal whatever this page shows.
    {:ok, assign(socket, username: "", error: nil, needs_setup?: Instance.needs_setup?())}
  end

  @impl true
  def handle_event("validate", %{"username" => username}, socket) do
    {:noreply, assign(socket, username: username, error: nil)}
  end

  def handle_event("register", %{"username" => username}, socket) do
    # Pushed to the hook, which takes it from here.
    {:noreply,
     socket |> assign(error: nil) |> push_event("ithibati:register", %{username: username})}
  end

  def handle_event("sign-in", _params, socket) do
    {:noreply, socket |> assign(error: nil) |> push_event("ithibati:authenticate", %{})}
  end

  # What the hook pushes back. A successful ceremony ends in the redirect the handler answered with,
  # so the only thing that reaches the LiveView is a failure.
  def handle_event("ithibati:failed", %{"error" => error}, socket) do
    {:noreply, assign(socket, error: CeremonyMessages.message(error))}
  end

  def handle_event("ithibati:done", _payload, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Invitation only
        <:subtitle :if={@needs_setup?}>
          Nobody has claimed this instance yet. Whoever does invites everyone else.
        </:subtitle>
        <:subtitle :if={not @needs_setup?}>
          Registration is by invitation. Sign in, or open the link somebody sent you.
        </:subtitle>
      </.header>

      <div :if={@current_account} class="alert alert-success mt-6">
        <span>
          Signed in as <strong>{@current_account.username}</strong>
          — <.link navigate={~p"/inside"} class="link">go inside</.link>
          or <.link href={~p"/session"} method="delete" class="link">sign out</.link>.
        </span>
      </div>

      <div :if={@error} class="alert alert-error mt-6"><span>{@error}</span></div>

      <form :if={@needs_setup?} phx-change="validate" phx-submit="register" class="mt-6">
        <.input
          name="username"
          value={@username}
          label="Username"
          required
          pattern={Layouts.username_pattern()}
          title="Letters, digits and underscores, up to thirty"
          placeholder="ada_lovelace"
        />
        <.button variant="primary">Claim this instance</.button>
      </form>

      <div class="mt-4">
        <.button phx-click="sign-in" class="btn">Sign in with a passkey</.button>
      </div>

      <Layouts.passkey_ceremony />
    </Layouts.app>
    """
  end
end
