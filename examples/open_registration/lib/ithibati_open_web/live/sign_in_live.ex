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

  # The way back in when the passkey is gone. Typed, not signed — but it still goes through the
  # hook, because the endpoint answers JSON and sets a session cookie.
  def handle_event("recover", %{"code" => code}, socket) do
    {:noreply, socket |> assign(error: nil) |> push_event("ithibati:recover", %{code: code})}
  end

  # What the hook pushes back. A successful ceremony ends in the redirect the handler answered with,
  # so the only thing that reaches the LiveView is a failure.
  def handle_event("ithibati:failed", %{"error" => error} = payload, socket) do
    {:noreply, assign(socket, error: message(error, payload["exception"]))}
  end

  def handle_event("ithibati:done", _payload, socket), do: {:noreply, socket}

  # The reasons arrive as the codes this application's own handler returned, plus the ones the
  # library produces. Turning them into sentences is the application's job — a library that shipped
  # the wording would be deciding the tone of somebody else's product.
  defp message("ceremony_failed", name) when is_binary(name), do: "Your browser refused: #{name}."
  defp message(error, _name), do: message(error)

  defp message("username_taken"), do: "That username is taken."

  defp message("invalid_username"),
    do: "A username is letters, digits and underscores, up to thirty characters."

  defp message("username_required"), do: "Pick a username to register."
  defp message("no_credentials"), do: "No passkey is registered here yet."
  defp message("invalid_code"), do: "That recovery code is not one we can use."
  defp message("ceremony_cancelled"), do: "The passkey prompt was dismissed."

  defp message("already_enrolled"), do: "That device already holds a passkey for this site."
  defp message("no_challenge"), do: "That took too long. Start again."
  defp message("malformed_credential"), do: "Your browser sent something this site cannot read."
  defp message("not_discoverable"), do: "That device will not store a passkey this site can find."
  defp message("unknown_credential"), do: "That passkey is not one this site knows."
  defp message("no_attested_credential"), do: "Your browser sent no passkey to store."
  defp message("credential_id_too_long"), do: "That passkey is bigger than this site can store."
  defp message("verification_failed"), do: "That did not check out. Start again."
  defp message("ceremony_failed"), do: "Your browser stopped partway through."
  defp message("recovery_failed"), do: "That code never reached us. Try again."
  defp message("unknown"), do: "That request failed without saying why."

  # Your own codes land here, and so do the two families that carry a suffix.
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

      <form phx-change="validate" phx-submit="register" class="mt-6">
        <.input
          name="username"
          value={@username}
          label="Username"
          required
          pattern={Layouts.username_pattern()}
          title="Letters, digits and underscores, up to thirty"
          placeholder="ada_lovelace"
        />
        <.button variant="primary">Register</.button>
      </form>

      <div class="mt-4">
        <.button phx-click="sign-in" class="btn">Sign in with a passkey</.button>
      </div>

      <form phx-submit="recover" class="mt-8">
        <.input name="code" value="" label="Lost your passkey? Use a recovery code" required />
        <.button class="btn">Sign in with a code</.button>
      </form>

      <%!-- The hook reads the paths off this element, because you chose the scope they are
      mounted under. It is empty on purpose: it drives the ceremony and renders nothing. --%>
      <div
        id="passkey"
        phx-hook="Ithibati.Web.Hooks.PasskeyCeremony"
        data-registration-challenge-url={~p"/auth/registration/challenge"}
        data-registration-url={~p"/auth/registration"}
        data-authentication-challenge-url={~p"/auth/authentication/challenge"}
        data-authentication-url={~p"/auth/authentication"}
        data-recovery-url={~p"/auth/recovery"}
      >
      </div>
    </Layouts.app>
    """
  end
end
