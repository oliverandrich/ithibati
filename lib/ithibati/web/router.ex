# The sentinel for the web half; `Ithibati.Web.Handler` says why it is this one.
if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.Router do
    @moduledoc """
    The five routes the ceremonies need, wired in one call.

        pipeline :ceremony do
          plug :accepts, ["json"]
          plug :fetch_session
          plug :protect_from_forgery
        end

        scope "/auth" do
          pipe_through :ceremony
          ithibati_routes handler: MyAppWeb.Auth, rp_name: "MyApp"
        end

    The suffixes belong to Ithibati and not to each application, so that there is no way to
    wire half of a ceremony: a mount chooses the prefix and nothing else. They are API from the
    first release, and changing one costs a major version.

    Four of the routes are the passkey ceremonies. The fifth, `/recovery`, takes a recovery code
    and ends in `c:Ithibati.Web.Handler.recovered/3`. That is the same place a verified assertion
    ends, reached the other way.
    """

    @doc """
    Generates the ceremony routes, dispatching to `handler`.

    `:handler` implements `Ithibati.Web.Handler`, and `:rp_name` is the name a passkey dialog
    shows. Both are required. `:user_verification` and `:seconds` are the two WebAuthn choices
    that belong to the application and not to Ithibati: whether the authenticator
    must confirm who is holding it, and how long a challenge stays acceptable. They default to
    `"preferred"` and sixty seconds.

    The macro records all of this on the routes instead of reading it from application
    configuration, so that two mounts (an administrative one and a public one, say) can answer to
    different rules.

    Naming the handler does not make your router compile-depend on it. Write it as an alias, the
    way you would write any module.
    """
    defmacro ithibati_routes(opts) do
      handler = resolved(Keyword.fetch!(opts, :handler), __CALLER__)
      collecting(__CALLER__.module)
      rp_name = Keyword.fetch!(opts, :rp_name)
      ceremony = Keyword.take(opts, [:user_verification, :seconds])

      quote bind_quoted: [handler: handler, rp_name: rp_name, ceremony: ceremony] do
        @ithibati_mounts handler

        # On the scope, not on each route. A sixth route added here without the handler would
        # be exactly the half-wired ceremony this exists to rule out.
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

    # Registered here, and written in the quote above, where `bind_quoted` has already reduced
    # every form the macro accepts to the module itself.
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
