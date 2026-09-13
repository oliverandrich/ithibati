defmodule Ithibati.Identity.RecoveryCodesRaceTest do
  @moduledoc """
  Eight callers spending the same code at once. Exactly one may win.

  Asserting that `redeem/1` refuses a spent code proves only that the two calls happened in order.
  What decides between callers who arrive together is that "unused" rides the `WHERE` of the update
  itself — and the only way to see that is to have them arrive together.

  Not async and not sandboxed, which `Ithibati.RaceCase` explains.
  """
  use Ithibati.RaceCase

  import Ithibati.DataCase, only: [user_fixture: 1]

  alias Ithibati.Identity.RecoveryCodes
  alias Ithibati.RecoveryCode
  alias Ithibati.TestUser

  @racers 8

  test "of #{@racers} callers spending one code, exactly one signs in" do
    user = user_fixture(%{email: "racer@example.test"})
    [code | _rest] = RecoveryCodes.regenerate(user)

    outcomes = racing(1..@racers, fn _ -> RecoveryCodes.redeem(code) end)

    assert Enum.count(outcomes, &match?({:ok, _account, _codes}, &1)) == 1
    assert Enum.count(outcomes, &(&1 == {:error, :invalid})) == @racers - 1

    # And the losers spent nothing: eleven unused codes, not eleven minus seven.
    assert RecoveryCodes.remaining(user) == 11
  end

  test "two callers spending the last two codes leave the account with a batch, not with nothing" do
    for round <- 1..10 do
      user = user_fixture(%{email: "refill#{round}@example.test"})
      codes = RecoveryCodes.regenerate(user)
      [last, second_last | spent] = Enum.reverse(codes)

      for code <- spent, do: {:ok, _, _} = RecoveryCodes.redeem(code)
      assert RecoveryCodes.remaining(user) == 2

      racing([last, second_last], &RecoveryCodes.redeem/1)

      left = RecoveryCodes.remaining(user)

      assert left == 12, "round #{round} left the account with #{left} codes"
    end
  end

  test "two callers regenerating at once leave one batch, not two" do
    for round <- 1..10 do
      user = user_fixture(%{email: "regen#{round}@example.test"})

      racing(1..2, fn _ -> RecoveryCodes.regenerate(user) end)

      live = RecoveryCodes.remaining(user)

      assert live == 12, "round #{round} left #{live} live codes"
    end
  end

  defp clear do
    TestRepo.delete_all(RecoveryCode)
    TestRepo.delete_all(TestUser)
  end
end
