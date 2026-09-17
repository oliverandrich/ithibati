if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.RouterTest do
    @moduledoc """
    The paths the macro generates are API from the first release: changing one costs a major
    version. Read off the router's own route table rather than requested through a connection, so
    the assertion is about what was declared and not about what happened to resolve.
    """
    use ExUnit.Case, async: true

    @expected [
      {"POST", "/auth/registration/challenge", :registration_challenge},
      {"POST", "/auth/registration", :registration},
      {"POST", "/auth/authentication/challenge", :authentication_challenge},
      {"POST", "/auth/authentication", :authentication},
      {"POST", "/auth/recovery", :recovery}
    ]

    # Filtered to one mount: the estate mounts the macro several times, and what is pinned is the
    # five suffixes one mount generates.
    test "the macro generates exactly the documented routes" do
      actual =
        Ithibati.TestRouter.__routes__()
        |> Enum.filter(&String.starts_with?(&1.path, "/auth"))
        |> Enum.map(&{&1.verb |> to_string() |> String.upcase(), &1.path, &1.plug_opts})

      assert Enum.sort(actual) == Enum.sort(@expected)
    end

    # In source order, duplicates kept: this is what the router mounted, not the set of handlers
    # it happens to name.
    test "the router reports every handler it mounts" do
      assert Ithibati.TestRouter.__ithibati_mounts__() == [
               Ithibati.TestHandler,
               Ithibati.TestExtensionHandler,
               Ithibati.TestSloppyHandler,
               Ithibati.TestHandler
             ]
    end

    # An attribute is the one that arrives as unresolved AST, which `Ithibati.Doctor` then raises
    # on, taking all thirteen of its answers down with it.
    test "however the handler was written" do
      Code.compile_quoted(
        quote do
          defmodule Ithibati.ProbeFormsRouter do
            use Phoenix.Router
            import Ithibati.Web.Router

            @attributed Ithibati.TestHandler

            scope("/a", do: ithibati_routes(handler: @attributed, rp_name: "probe"))

            scope("/b",
              do: ithibati_routes(handler: Ithibati.TestSloppyHandler, rp_name: "probe")
            )

            scope("/c",
              do: ithibati_routes(handler: :"Elixir.Ithibati.TestExtensionHandler", rp_name: "p")
            )
          end
        end
      )

      assert Ithibati.ProbeFormsRouter.__ithibati_mounts__() == [
               Ithibati.TestHandler,
               Ithibati.TestSloppyHandler,
               Ithibati.TestExtensionHandler
             ]
    end
  end
end
