# Guarded rather than kept off `elixirc_paths`, which is read in `project/0` — and a dependency's
# `project/0` can see nothing about the project being built: `Code.ensure_loaded?` is false there
# even where the module exists, and `deps_path()`/`build_path()` name directories that do not. Here
# the check runs when the module compiles, by which point a consumer's dependencies are loaded, so
# an application that took this library without Phoenix simply does not get this module.
if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.Hooks do
    @moduledoc """
    The colocated route for this library's JavaScript.

    A consumer whose bundler resolves `phoenix-colocated` imports the hooks from
    `phoenix-colocated/ithibati` and needs no path into `deps/`. The alternative is to import
    `priv/static/ithibati.js` directly; see the README.

    The hook body re-exports rather than repeating the client code, so the two routes cannot
    disagree about what a ceremony does — a test reads both files and holds them to the same name,
    because a hook registered under the wrong one does not fail, it never mounts.
    """
    use Phoenix.Component

    # Nothing renders this, and `@doc false` keeps it out of the published documentation where it
    # would read as something to call. It exists so that compiling this module runs LiveView's
    # extraction, which is what writes the manifest a consumer imports as
    # `phoenix-colocated/ithibati`. A colocated script tag is removed from the output, so calling it
    # would produce nothing anyway.
    @doc false
    def hooks(assigns) do
      ~H"""
      <script :type={Phoenix.LiveView.ColocatedHook} name=".PasskeyCeremony">
        export {PasskeyCeremony as default} from "ithibati"
      </script>
      """
    end
  end
end
