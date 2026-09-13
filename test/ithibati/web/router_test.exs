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
      {"POST", "/auth/authentication", :authentication}
    ]

    # Filtered to one mount: the test estate mounts twice, and what is being pinned is the four
    # suffixes a mount generates, not how many times the suite happens to call the macro.
    test "the macro generates exactly the documented routes" do
      actual =
        Ithibati.TestRouter.__routes__()
        |> Enum.filter(&String.starts_with?(&1.path, "/auth"))
        |> Enum.map(&{&1.verb |> to_string() |> String.upcase(), &1.path, &1.plug_opts})

      assert Enum.sort(actual) == Enum.sort(@expected)
    end
  end
end
