defmodule IthibatiEmailWeb.SignInLive do
  @moduledoc "Requests a registration link by email, or starts sign-in for an existing passkey."
  use IthibatiEmailWeb, :live_view

  alias IthibatiEmail.Registration
  alias IthibatiEmailWeb.CeremonyMessages

  @mailbox? Application.compile_env(:ithibati_email, :dev_routes, false)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       email: "",
       error: nil,
       registration_open?: Registration.open?(),
       mailbox?: @mailbox?
     )}
  end

  @impl true
  def handle_event("validate", %{"email" => email}, socket) when is_binary(email),
    do: {:noreply, assign(socket, email: email)}

  def handle_event("request-invitation", params, socket) do
    _result = Registration.request_invitation(params["email"])

    {:noreply,
     put_flash(
       socket,
       :info,
       "If registration is available for this email, a registration link will arrive shortly."
     )}
  end

  def handle_event("sign-in", _params, socket),
    do: {:noreply, socket |> assign(error: nil) |> push_event("ithibati:authenticate", %{})}

  def handle_event("ithibati:failed", %{"error" => error} = payload, socket),
    do: {:noreply, assign(socket, error: CeremonyMessages.message(error, payload["exception"]))}

  def handle_event("ithibati:done", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Register with your email
        <:subtitle>Get a registration link, then create your passkey.</:subtitle>
      </.header>

      <div :if={@current_account} class="alert alert-success mt-6">
        <span>
          Signed in as <strong>{@current_account.email}</strong>
          — <.link navigate={~p"/inside"} class="link">go inside</.link>
          or <.link href={~p"/session"} method="delete" class="link">sign out</.link>.
        </span>
      </div>

      <div :if={@error} class="alert alert-error mt-6"><span>{@error}</span></div>

      <form
        :if={@registration_open?}
        id="request-invitation"
        phx-change="validate"
        phx-submit="request-invitation"
        class="mt-6"
      >
        <.input name="email" type="email" value={@email} label="Email address" required />
        <.button variant="primary">Email me a registration link</.button>
      </form>

      <p :if={not @registration_open?}>New registrations are currently unavailable.</p>

      <div class="mt-4">
        <.button phx-click="sign-in">Sign in with a passkey</.button>
      </div>

      <p :if={@mailbox?} class="mt-6">
        Testing locally? <.link href="/dev/mailbox" target="_blank" class="link">Open the local mailbox</.link>.
      </p>

      <Layouts.passkey_ceremony />
    </Layouts.app>
    """
  end
end
