defmodule Ithibati.Identity.PasskeysRaceTest do
  @moduledoc """
  Two people deleting two *different* passkeys at the same moment. One of them has to be refused.

  This is the case `docs/design.md` decision 8 names as the one a predicate in the `WHERE` cannot
  carry alone: the two deletes aim at different rows, so neither waits on the other, both snapshots
  still hold the sibling, and an account with two passkeys ends with none. Asserting that
  `delete_key/2` refuses the last one proves only that the two calls happened in order — the guard
  that decides between callers who arrive together is the lock on the owner's row, and the only way
  to see it is to have them arrive together.

  Not async and not sandboxed: a rollback per test would mean a single connection and no race to
  lose. Same shape as `Ithibati.Identity.RecoveryCodesRaceTest`, and for the same reason.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Ithibati.DataCase, only: [user_fixture: 1, key_fixture: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Ithibati.Identity.Passkeys
  alias Ithibati.TestRepo
  alias Ithibati.TestUser
  alias Ithibati.UserKey

  @rounds 10

  setup_all do
    # Without two connections the second deleter queues instead of racing, and the test still passes
    # — as a sequence, which is the one thing this module exists to rule out.
    pool = TestRepo.config()[:pool_size]

    assert pool >= 2, "pool_size is #{pool}, so two racers cannot be in flight at once"

    Sandbox.mode(TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)
  end

  setup do
    on_exit(&clear/0)
  end

  test "of two callers deleting two different passkeys, one is refused every time" do
    for round <- 1..@rounds do
      account = user_fixture(%{email: "racer#{round}@example.test"})
      keys = for label <- ~w(one two), do: key_fixture(account, %{label: label})

      outcomes =
        keys
        |> Task.async_stream(&Passkeys.delete_key(account, &1.id), max_concurrency: 2)
        |> Enum.map(fn
          {:ok, outcome} -> outcome
          {:exit, reason} -> flunk("a racer never finished: #{inspect(reason)}")
        end)

      left = TestRepo.aggregate(from(k in UserKey, where: k.user_id == ^account.id), :count)

      assert left == 1, "round #{round} left the account with #{left} passkeys"
      assert Enum.count(outcomes, &match?({:ok, _key}, &1)) == 1
      assert {:error, :last_key} in outcomes

      clear()
    end
  end

  defp clear do
    TestRepo.delete_all(UserKey)
    TestRepo.delete_all(TestUser)
  end
end
