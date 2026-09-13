defmodule IthibatiInvitesWeb.InsideLive do
  @moduledoc """
  Behind `{:require_account, to: "/"}`, and the only place invitations are written.

  Nothing here checks who is asking: by the time `mount/3` runs, the gate has either assigned an
  account or sent the visitor away. What an account may *do* — whether everyone can invite, or only
  some — is this application's question and would live here, not in the library.
  """
  use IthibatiInvitesWeb, :live_view

  alias IthibatiInvites.Accounts.Invitation
  alias IthibatiInvites.Repo

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, username: "", link: nil, error: nil)}
  end

  @impl true
  def handle_event("validate", %{"username" => username}, socket) do
    {:noreply, assign(socket, username: username, error: nil)}
  end

  def handle_event("invite", %{"username" => username}, socket) do
    %Invitation{}
    |> Invitation.changeset(%{"username" => username})
    |> Repo.insert()
    |> case do
      # The token is the only copy there will ever be: the row holds its sha256, and the virtual
      # field is empty on anything read back later. So it goes on the screen now or not at all.
      {:ok, invitation} ->
        {:noreply, assign(socket, link: url(~p"/invite/#{invitation.token}"), username: "")}

      {:error, changeset} ->
        {:noreply, assign(socket, error: changeset_message(changeset))}
    end
  end

  defp changeset_message(changeset) do
    case changeset.errors do
      [{:username, {message, _opts}} | _rest] -> "Username #{message}."
      _other -> "That invitation could not be written."
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Inside
        <:subtitle>Signed in as {@current_account.username}.</:subtitle>
      </.header>

      <h2 class="mt-8 text-lg font-semibold">Invite somebody</h2>

      <p class="mt-2 text-sm opacity-70">
        An invitation names the username its holder will get. They cannot change it — the library
        refuses an acceptance whose account carries a different one.
      </p>

      <form phx-change="validate" phx-submit="invite" class="mt-4 flex gap-2">
        <input
          type="text"
          name="username"
          value={@username}
          required
          pattern={Layouts.username_pattern()}
          title="Letters, digits and underscores, up to thirty"
          placeholder="their username"
          class="input flex-1"
        />
        <.button variant="primary">Create a link</.button>
      </form>

      <div :if={@error} class="alert alert-error mt-4"><span>{@error}</span></div>

      <div :if={@link} class="alert alert-success mt-4">
        <span>
          Send them this, and keep no copy — it is shown once:
          <code class="block mt-2 break-all">{@link}</code>
        </span>
      </div>

      <p class="mt-8">
        <.link navigate={~p"/"} class="link">Back</.link>
        — <.link href={~p"/session"} method="delete" class="link">sign out</.link>
      </p>
    </Layouts.app>
    """
  end
end
