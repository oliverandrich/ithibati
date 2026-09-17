# The sentinel for the web half; `Ithibati.Web.Handler` says why it is this one.
if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Ithibati.Web.Hooks do
    @moduledoc """
    Exports the passkey browser hook through LiveView's colocated manifest.

    Set `ITHIBATI_COLOCATED_HOOKS=1` when building and recompile Ithibati to generate
    `phoenix-colocated/ithibati`. That import and the plain `ithibati` package both register
    `Ithibati.Web.Hooks.PasskeyCeremony` and use the same client implementation.

    [Browser imports](ceremonies.md#browser-imports) covers both options. Applications importing
    the plain package do not need to enable the colocated compiler.
    """
    use Phoenix.Component

    # The component gives LiveView's compiler a colocated script to extract. It renders no UI
    # and is not an application API.
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
