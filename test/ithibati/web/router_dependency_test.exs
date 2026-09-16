if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.RouterDependencyTest do
    @moduledoc """
    Naming a handler does not make a consumer's router compile-depend on it.

    No other test can see this. A correct resolution and a careless one reach the same module, and
    what differs is what the compiler wrote down. `Kernel.LexicalTracker` is not public API and
    answers with a bare tuple, so the positions are pinned by a module that has to be a compile
    reference and one that has to be a runtime one.
    """
    use ExUnit.Case, async: true

    test "the handler is a runtime reference and not a compile-time one" do
      me = self()

      Code.compile_quoted(
        quote do
          defmodule Ithibati.ProbeDependencyRouter do
            use Phoenix.Router
            import Ithibati.Web.Router

            @after_compile {__MODULE__, :__record__}

            def __record__(env, _bytecode),
              do:
                send(
                  unquote(me),
                  {:references, Kernel.LexicalTracker.references(env.lexical_tracker)}
                )

            # Through an alias, which is what a consumer writes. A resolution built from the alias
            # segments would record `Elixir.Aliased` below instead.
            scope "/probe" do
              alias Ithibati.TestHandler, as: Aliased

              ithibati_routes(handler: Aliased, rp_name: "Ithibati Probe")
            end
          end
        end
      )

      assert_receive {:references, references}
      assert tuple_size(references) == 4, "references/1 changed shape: #{inspect(references)}"

      compile = elem(references, 0)
      runtime = elem(references, 2)

      assert Phoenix.Router in compile, "position 0 is not the compile-time list"
      assert Ithibati.Web.PasskeyController in runtime, "position 2 is not the runtime list"

      refute Ithibati.TestHandler in compile,
             "every edit to the handler, and to anything it reaches, now rebuilds the router"

      assert Ithibati.TestHandler in runtime
    end
  end
end
