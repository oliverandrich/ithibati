# The sentinel for the web half; `Ithibati.Web.Handler` says why it is this one.
if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.Hooks do
    @moduledoc """
    The colocated route for Ithibati's JavaScript.

    An application whose bundler resolves `phoenix-colocated` imports the hooks from
    `phoenix-colocated/ithibati` and needs no path into `deps/`. The alternative is to import
    `priv/static/ithibati.js` directly; [Registering and signing
    in](ceremonies.md#the-javascript) shows both.

    The hook body re-exports the client code instead of repeating it, so the two routes cannot
    disagree about what a ceremony does. A test reads both files and holds them to the same name,
    because a hook registered under the wrong name does not fail, it never mounts.
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
