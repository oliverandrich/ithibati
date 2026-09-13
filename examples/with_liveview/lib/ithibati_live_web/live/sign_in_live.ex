defmodule IthibatiLiveWeb.SignInLive do
  @moduledoc """
  The LiveView says *when* a ceremony starts; the hook does the round-trips.

  That split is not a style choice. A ceremony ends in a session cookie and a LiveView cannot set
  one, so the hook posts to the endpoints over `fetch` and follows the redirect the handler answers
  with. What a LiveView is good at — validating the fields before any of that begins — is what it
  does here.
  """
  use IthibatiLiveWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, email: "", error: nil)}
  end

  @impl true
  def handle_event("validate", %{"email" => email}, socket) do
    {:noreply, assign(socket, email: email, error: nil)}
  end

  def handle_event("register", %{"email" => email}, socket) do
    # Pushed to the hook, which takes it from here.
    {:noreply, socket |> assign(error: nil) |> push_event("ithibati:register", %{email: email})}
  end

  def handle_event("sign-in", _params, socket) do
    {:noreply, socket |> assign(error: nil) |> push_event("ithibati:authenticate", %{})}
  end

  # What the hook pushes back. A successful ceremony ends in the redirect the handler answered with,
  # so the only thing that reaches the LiveView is a failure.
  def handle_event("ithibati:failed", %{"error" => error}, socket) do
    {:noreply, assign(socket, error: error)}
  end

  def handle_event("ithibati:done", _payload, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-2xl font-semibold">Ithibati with LiveView</h1>

      <p :if={@current_account} class="mt-4 rounded bg-green-50 p-3">
        Signed in as {@current_account.email} —
        <.link navigate={~p"/inside"} class="underline">go inside</.link>
        or <.link href={~p"/session"} method="delete" class="underline">sign out</.link>.
      </p>

      <p :if={@error} class="mt-4 rounded bg-red-50 p-3">Ceremony failed: {@error}</p>

      <form phx-change="validate" phx-submit="register" class="mt-6 flex gap-2">
        <input
          type="email"
          name="email"
          value={@email}
          required
          placeholder="you@example.com"
          class="flex-1 rounded border px-3 py-2"
        />
        <button class="rounded bg-black px-4 py-2 text-white">Register</button>
      </form>

      <p class="mt-4">
        <button phx-click="sign-in" class="rounded border px-4 py-2">Sign in with a passkey</button>
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
    </div>
    """
  end
end
