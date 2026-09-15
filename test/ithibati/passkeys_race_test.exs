defmodule Ithibati.Identity.PasskeysRaceTest do
  @moduledoc """
  Two people deleting two *different* passkeys at the same moment. One of them has to be refused.

  This is the case a predicate in the `WHERE` cannot
  carry alone: the two deletes aim at different rows, so neither waits on the other, both snapshots
  still hold the sibling, and an account with two passkeys ends with none. Asserting that
  `delete_key/2` refuses the last one proves only that the two calls happened in order — the guard
  that decides between callers who arrive together is the lock on the owner's row, and the only way
  to see it is to have them arrive together.

  Not async and not sandboxed, which `Ithibati.RaceCase` explains.
  """
  use Ithibati.RaceCase

  import Ecto.Query
  import Ithibati.DataCase, only: [user_fixture: 1, key_fixture: 2]

  alias Ithibati.Identity.Passkeys
  alias Ithibati.TestUser
  alias Ithibati.UserKey

  @rounds 10

  test "of two callers deleting two different passkeys, one is refused every time" do
    for round <- 1..@rounds do
      account = user_fixture(%{email: "racer#{round}@example.test"})
      keys = for label <- ~w(one two), do: key_fixture(account, %{label: label})

      outcomes = racing(keys, &Passkeys.delete_key(account, &1.id))

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
