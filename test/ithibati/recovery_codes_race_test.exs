defmodule Ithibati.Identity.RecoveryCodesRaceTest do
  @moduledoc """
  Eight callers spending the same code at once. Exactly one may win.

  Asserting that `redeem/1` refuses a spent code proves only that the two calls happened in order.
  What decides between callers who arrive together is that "unused" rides the `WHERE` of the update
  itself — and the only way to see that is to have them arrive together.

  Not async and not sandboxed: a rollback per test would mean a single connection and no race to
  lose. Same shape as `Ithibati.BootstrapTest`, and for the same reason.
  """
  use ExUnit.Case, async: false

  import Ithibati.DataCase, only: [user_fixture: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias Ithibati.Identity.RecoveryCodes
  alias Ithibati.RecoveryCode
  alias Ithibati.TestRepo
  alias Ithibati.TestUser

  @racers 8

  setup_all do
    # Without enough connections the racers queue instead of racing, and the test still passes — as
    # a sequence, which is the one thing this module exists to rule out.
    pool = TestRepo.config()[:pool_size]

    assert pool >= @racers,
           "pool_size is #{pool}, so only that many of #{@racers} racers can be in flight at once"

    Sandbox.mode(TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)
  end

  setup do
    on_exit(&clear/0)
  end

  test "of #{@racers} callers spending one code, exactly one signs in" do
    user = user_fixture(%{email: "racer@example.test"})
    [code | _rest] = RecoveryCodes.regenerate(user)

    outcomes =
      1..@racers
      |> Task.async_stream(fn _ -> RecoveryCodes.redeem(code) end, max_concurrency: @racers)
      |> Enum.map(fn
        {:ok, outcome} -> outcome
        {:exit, reason} -> flunk("a racer never finished: #{inspect(reason)}")
      end)

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

      [last, second_last]
      |> Task.async_stream(&RecoveryCodes.redeem/1, max_concurrency: 2)
      |> Stream.run()

      left = RecoveryCodes.remaining(user)

      assert left == 12, "round #{round} left the account with #{left} codes"
    end
  end

  test "two callers regenerating at once leave one batch, not two" do
    for round <- 1..10 do
      user = user_fixture(%{email: "regen#{round}@example.test"})

      1..2
      |> Task.async_stream(fn _ -> RecoveryCodes.regenerate(user) end, max_concurrency: 2)
      |> Stream.run()

      live = RecoveryCodes.remaining(user)

      assert live == 12, "round #{round} left #{live} live codes"
    end
  end

  defp clear do
    TestRepo.delete_all(RecoveryCode)
    TestRepo.delete_all(TestUser)
  end
end
