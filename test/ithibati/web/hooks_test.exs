defmodule Ithibati.Web.HooksTest do
  @moduledoc """
  One claim in two halves: the two delivery routes register the hook under one name, and the
  colocated one carries no second copy of the client code.

  Both halves fail silently in production. A hook registered under the wrong name does not error,
  it never mounts; a second copy does not error either, it drifts. Read out of the two source files
  rather than compared against a name written here a third time, and source-level rather than
  through the module, so this holds on the build where the optional dependencies are absent and
  `Ithibati.Web.Hooks` is never compiled.
  """
  use ExUnit.Case, async: true

  @component Path.expand("../../../lib/ithibati/web/hooks.ex", __DIR__)
  @javascript Path.expand("../../../priv/static/ithibati.js", __DIR__)

  # The whole of the hook body. Asserted exactly rather than probed for a string a copy might happen
  # to omit: nothing else can be in there if this matches.
  @re_export ~s|export {PasskeyCeremony as default} from "ithibati"|

  test "both routes register one name, and the colocated one holds only a re-export" do
    component = File.read!(@component)

    [_, module] = Regex.run(~r/defmodule (\S+) do/, component)
    [_, hook] = Regex.run(~r/ColocatedHook\} name="\.(\w+)"/, component)

    assert File.read!(@javascript) =~ ~s|"#{module}.#{hook}":|

    [_, body] = Regex.run(~r|ColocatedHook\}[^>]*>(.*?)</script>|s, component)
    assert String.trim(body) == @re_export
  end
end
