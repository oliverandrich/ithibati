if Code.ensure_loaded?(Phoenix.Router) do
  defmodule Ithibati.Web.Router do
    @moduledoc """
    The four routes the passkey ceremonies need, wired in one call.

        scope "/auth" do
          pipe_through :browser
          ithibati_routes handler: MyApp.Auth, rp_name: "MyApp"
        end

    The four suffixes belong to this library rather than to each consumer, so that there is no way
    to wire half of a ceremony: a mount chooses the prefix and nothing else. They are API from the
    first release — changing one costs a major version.
    """

    @doc """
    Generates the ceremony routes, dispatching to `handler`.

    `:handler` implements `Ithibati.Web.Handler` and `:rp_name` is the name a passkey dialog shows;
    both are required. `:user_verification` and `:seconds` are the two WebAuthn choices
    `docs/design.md` calls the application's rather than this library's — whether the authenticator
    must confirm who is holding it, and how long a challenge stays acceptable. They default to
    `"preferred"` and sixty seconds.

    All of it is recorded on the routes rather than read from application configuration, so that two
    mounts — an administrative one and a public one, say — can answer to different rules.
    """
    defmacro ithibati_routes(opts) do
      handler = Keyword.fetch!(opts, :handler)
      rp_name = Keyword.fetch!(opts, :rp_name)
      ceremony = Keyword.take(opts, [:user_verification, :seconds])

      quote bind_quoted: [handler: handler, rp_name: rp_name, ceremony: ceremony] do
        # On the scope rather than on each route: a fifth route added here without the handler would
        # be exactly the half-wired ceremony this exists to rule out.
        scope "/", Ithibati.Web,
          private: %{ithibati: %{handler: handler, rp_name: rp_name, ceremony: ceremony}} do
          post("/registration/challenge", PasskeyController, :registration_challenge)
          post("/registration", PasskeyController, :registration)
          post("/authentication/challenge", PasskeyController, :authentication_challenge)
          post("/authentication", PasskeyController, :authentication)
        end
      end
    end
  end
end
