defmodule Ithibati.BootstrapTest do
  @moduledoc """
  An instance can be set up exactly once, driven concurrently.

  Asserting that the unique index exists would prove nothing about what it is for. The index is what
  decides between callers who all try, so eight of them try at once and exactly one survives.

  Not async and not sandboxed — a rollback per test would mean a single connection and no race to
  lose.
  """
  use ExUnit.Case, async: false

  import Ithibati.DataCase, only: [user_fixture: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias Ithibati.Bootstrap
  alias Ithibati.TestRepo
  alias Ithibati.TestUser

  @racers 8

  setup_all do
    # Without enough connections the racers queue instead of racing, and the test still passes — as a
    # sequence, which is the one thing this module exists to rule out. A smaller machine has to make
    # that red rather than quiet.
    pool = TestRepo.config()[:pool_size]

    assert pool >= @racers,
           "pool_size is #{pool}, so only that many of #{@racers} racers can be in flight at once"

    Sandbox.mode(TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)
  end

  setup do
    on_exit(&clear/0)
  end

  test "of #{@racers} accounts racing to set the instance up, one wins and the rest are told why" do
    outcomes =
      1..@racers
      |> Task.async_stream(&race("racer#{&1}@example.test"), max_concurrency: @racers)
      |> Enum.map(fn
        {:ok, outcome} -> outcome
        {:exit, reason} -> flunk("a racer never finished: #{inspect(reason)}")
      end)

    assert Enum.count(outcomes, &match?({:ok, _}, &1)) == 1
    assert TestRepo.aggregate(Bootstrap, :count) == 1

    # Told apart from an invalid form: the caller can answer "somebody else already did this"
    # instead of showing a field error on an address that is fine.
    for {:error, changeset} <- outcomes do
      assert Keyword.has_key?(changeset.errors, :claimed)
    end
  end

  # The whole reason this is a row rather than a flag on the account. Deleting the account that set
  # an instance up must not make a second setup possible.
  test "the record outlives the account that made it" do
    user = user_fixture(%{email: "founder@example.test"})
    {:ok, claim} = TestRepo.insert(Bootstrap.changeset(%Bootstrap{}, %{user_id: user.id}))

    {:ok, _} = TestRepo.delete(user)

    assert %Bootstrap{user_id: nil} = TestRepo.get!(Bootstrap, claim.id)
    assert {:error, changeset} = TestRepo.insert(Bootstrap.changeset(%Bootstrap{}, %{}))
    assert Keyword.has_key?(changeset.errors, :claimed)
  end

  defp race(email) do
    user = user_fixture(%{email: email})
    TestRepo.insert(Bootstrap.changeset(%Bootstrap{}, %{user_id: user.id}))
  end

  defp clear do
    TestRepo.delete_all(Bootstrap)
    TestRepo.delete_all(TestUser)
  end
end
