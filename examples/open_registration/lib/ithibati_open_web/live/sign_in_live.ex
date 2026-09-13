defmodule IthibatiOpenWeb.SignInLive do
  @moduledoc """
  The LiveView says *when* a ceremony starts; the hook does the round-trips.

  That split is not a style choice. A ceremony ends in a session cookie and a LiveView cannot set
  one, so the hook posts to the endpoints over `fetch` and follows the redirect the handler answers
  with. What a LiveView is good at — validating the fields before any of that begins — is what it
  does here.
  """
  use IthibatiOpenWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, username: "", error: nil)}
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
    {:noreply, assign(socket, error: message(error))}
  end

  def handle_event("ithibati:done", _payload, socket), do: {:noreply, socket}

  # The reasons arrive as the codes this application's own handler returned, plus the ones the
  # library produces. Turning them into sentences is the application's job — a library that shipped
  # the wording would be deciding the tone of somebody else's product.
  defp message("username_taken"), do: "That username is taken."

  defp message("invalid_username"),
    do: "A username is letters, digits and underscores, up to thirty characters."

  defp message("username_required"), do: "Pick a username to register."
  defp message("no_credentials"), do: "No passkey is registered here yet."
  defp message("ceremony_cancelled"), do: "The passkey prompt was dismissed."
  defp message(other), do: "Something went wrong: #{other}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Open registration
        <:subtitle>Pick a username, prove it with a passkey. That is the whole policy.</:subtitle>
      </.header>

      <div :if={@current_account} class="alert alert-success mt-6">
        <span>
          Signed in as <strong>{@current_account.username}</strong>
          — <.link navigate={~p"/inside"} class="link">go inside</.link>
          or <.link href={~p"/session"} method="delete" class="link">sign out</.link>.
        </span>
      </div>

      <div :if={@error} class="alert alert-error mt-6"><span>{@error}</span></div>

      <form phx-change="validate" phx-submit="register" class="mt-6 flex gap-2">
        <input
          type="text"
          name="username"
          value={@username}
          required
          pattern={Layouts.username_pattern()}
          title="Letters, digits and underscores, up to thirty"
          placeholder="a username"
          class="input flex-1"
        />
        <.button variant="primary">Register</.button>
      </form>

      <p class="mt-4">
        <.button phx-click="sign-in" class="btn">Sign in with a passkey</.button>
      </p>

      <%!-- The hook reads the paths off this element, because you chose the scope they are
      mounted under. It is empty on purpose: it drives the ceremony and renders nothing. --%>
      <div
        id="passkey"
        phx-hook="Ithibati.Web.Hooks.PasskeyCeremony"
        data-registration-challenge-url={~p"/auth/registration/challenge"}
        data-registration-url={~p"/auth/registration"}
        data-authentication-challenge-url={~p"/auth/authentication/challenge"}
        data-authentication-url={~p"/auth/authentication"}
      >
      </div>
    </Layouts.app>
    """
  end
end
