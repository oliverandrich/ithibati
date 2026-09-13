defmodule IthibatiOpenWeb.Router do
  use IthibatiOpenWeb, :router

  import Ithibati.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {IthibatiOpenWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug Ithibati.Web.Gate, :current_account
  end

  # Its own pipeline, not `:browser`. These endpoints answer JSON, and `:browser`'s
  # `accepts ["html"]` refuses the hook's request with a 406 before the controller is reached —
  # which is exactly how this example found the mistake in the library's README.
  pipeline :ceremony do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
  end

  scope "/auth" do
    pipe_through :ceremony
    # The name the passkey dialog shows, and the only thing separating this example's credentials
    # from the other's: a relying-party id is a *host*, so both examples on localhost share one
    # scope however different their databases are.
    ithibati_routes handler: IthibatiOpen.Auth, rp_name: "Ithibati, open registration"
  end

  scope "/", IthibatiOpenWeb do
    pipe_through :browser

    live_session :public, on_mount: [{Ithibati.Web.Gate, :current_account}] do
      live "/", SignInLive
    end

    live_session :members, on_mount: [{Ithibati.Web.Gate, {:require_account, to: "/"}}] do
      live "/inside", InsideLive
    end

    get "/recovery-codes", SessionController, :recovery_codes
    delete "/session", SessionController, :sign_out
  end
end
