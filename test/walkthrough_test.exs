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

  import Ithibati.Vocabulary

  alias Ithibati.Vocabulary

  @guide File.read!("docs/getting_started.md")
  @example File.read!("examples/open_registration/lib/ithibati_open_web/live/sign_in_live.ex")
  @reason ~r/message\("([a-z_]+)"\)/

  test "the guide and the example answer for the same reasons" do
    assert_same(
      Vocabulary.codes_in(@guide, @reason),
      Vocabulary.codes_in(@example, @reason),
      "the guide",
      "the example"
    )
  end
end
