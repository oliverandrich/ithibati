# The sentinel for the web half; `Ithibati.Web.Handler` says why it is this one.
if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.Router do
    @moduledoc """
    Mounts registration, authentication and recovery endpoints in a Phoenix router.

    Import this module and use a pipeline that accepts JSON, fetches the session and checks CSRF:

        pipeline :ceremony do
          plug :accepts, ["json"]
          plug :fetch_session
          plug :protect_from_forgery
        end

        scope "/auth" do
          pipe_through :ceremony
          ithibati_routes handler: MyAppWeb.Auth, rp_name: "MyApp"
        end

    The mount adds five POST paths relative to its scope: `/registration/challenge`,
    `/registration`, `/authentication/challenge`, `/authentication` and `/recovery`.
    Their suffixes are fixed; the application chooses the scope prefix.
    """

    @doc """
    Generates the five POST routes with settings local to this mount.

    ## Options

      * `:handler` — required module implementing `Ithibati.Web.Handler`.
      * `:rp_name` — required relying-party display name for passkey dialogs.
      * `:user_verification` — `"required"`, `"preferred"` (default) or `"discouraged"`.
      * `:seconds` — positive integer challenge lifetime; defaults to `60`.

    Different mounts can use different handlers and ceremony settings. The controller derives the
    relying-party ID and origin from the endpoint unless the handler overrides `relying_party/2`.

    A handler alias is resolved without introducing a compile-time dependency on that handler.
    """
    defmacro ithibati_routes(opts) do
      handler = resolved(Keyword.fetch!(opts, :handler), __CALLER__)
      collecting(__CALLER__.module)
      rp_name = Keyword.fetch!(opts, :rp_name)
      ceremony = Keyword.take(opts, [:user_verification, :seconds])

      quote bind_quoted: [handler: handler, rp_name: rp_name, ceremony: ceremony] do
        @ithibati_mounts handler

        # Scope-level settings apply consistently to every generated endpoint.
        scope "/", Ithibati.Web,
          private: %{ithibati: %{handler: handler, rp_name: rp_name, ceremony: ceremony}} do
          post("/registration/challenge", PasskeyController, :registration_challenge)
          post("/registration", PasskeyController, :registration)
          post("/authentication/challenge", PasskeyController, :authentication_challenge)
          post("/authentication", PasskeyController, :authentication)
          post("/recovery", PasskeyController, :recovery)
        end
      end
    end

    @doc false
    defmacro __before_compile__(_env) do
      quote do
        @doc false
        def __ithibati_mounts__, do: Enum.reverse(@ithibati_mounts)
      end
    end

    # Register once even when a router mounts several handlers; the quoted code records each mount.
    defp collecting(module) do
      unless Module.has_attribute?(module, :ithibati_mounts) do
        Module.register_attribute(module, :ithibati_mounts, accumulate: true)
        Module.put_attribute(module, :before_compile, __MODULE__)
      end
    end

    # `Plug.Builder.expand_alias/2`, verbatim. An alias expanded inside a function body is a
    # runtime reference, so the caller's aliases are consulted and the router takes no compile
    # dependency on the handler. `Ithibati.Web.RouterDependencyTest` holds it.
    defp resolved({:__aliases__, _, _} = alias, caller),
      do: Macro.expand(alias, %{caller | function: {:init, 1}})

    defp resolved(other, _caller), do: other
  end
end
