defmodule Ithibati.WalkthroughTest do
  @moduledoc """
  The reasons the setup guide prints are the ones the example it transcribes answers for.

  `docs/getting_started.md` walks somebody to a working sign-in, and its `message/1` block is a
  copy of `IthibatiOpenWeb.SignInLive`'s. A reader copies that block into their own page, so a
  code the guide knows and the example does not is a sentence nobody wrote, and a code the example
  gained and the guide did not is a raw atom in somebody's interface.

  Nothing else holds the two together. Adding `already_enrolled` to the example left the guide
  behind, and a review caught it where no test did.

  The codes rather than the lines, so that reformatting either file proves nothing and a new
  reason proves everything.
  """
  use ExUnit.Case, async: true

  @guide File.read!("docs/getting_started.md")
  @example File.read!("examples/open_registration/lib/ithibati_open_web/live/sign_in_live.ex")

  defp reasons(source) do
    ~r/message\("([a-z_]+)"\)/
    |> Regex.scan(source)
    |> Enum.map(fn [_, reason] -> reason end)
    |> MapSet.new()
  end

  test "the guide and the example answer for the same reasons" do
    guide = reasons(@guide)
    example = reasons(@example)

    refute MapSet.size(guide) == 0, "no reasons found at all — this test would pass vacuously"

    assert MapSet.equal?(guide, example), """
    docs/getting_started.md and the open_registration example disagree about which reasons a page
    answers for.

    Only in the guide:   #{inspect(Enum.sort(MapSet.difference(guide, example)))}
    Only in the example: #{inspect(Enum.sort(MapSet.difference(example, guide)))}
    """
  end
end
