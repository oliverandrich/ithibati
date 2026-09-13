defmodule Ithibati.BootstrapTest do
  @moduledoc """
  An instance can be set up exactly once, driven concurrently.

  Asserting that the unique index exists would prove nothing about what it is for. The index is what
  decides between callers who all try, so eight of them try at once and exactly one survives.

  Twice, because the two prove different things: the first races the index itself, and would still
  hold if `Ithibati.Identity.Instance` were deleted; the second races the path an application takes
  and adds what only that path can lose — an account left behind by a caller who was refused.

  Not async and not sandboxed — a rollback per test would mean a single connection and no race to
  lose.
  """
  use ExUnit.Case, async: false

  import Ithibati.DataCase, only: [user_changeset: 1, user_fixture: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Multi
  alias Ithibati.Bootstrap
  alias Ithibati.Identity.Instance
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
    outcomes = racing(&race/1)

    assert Enum.count(outcomes, &match?({:ok, _}, &1)) == 1
    assert TestRepo.aggregate(Bootstrap, :count) == 1

    # Told apart from an invalid form: the caller can answer "somebody else already did this"
    # instead of showing a field error on an address that is fine. Counted rather than walked, for
    # the reason the test below gives.
    assert Enum.count(outcomes, &match?({:error, %{errors: [claimed: _]}}, &1)) == @racers - 1
  end

  # The test above races the index directly; this one races the way an application reaches it, and the
  # difference is what it proves. A registration is an account *and* a claim in one transaction, so a
  # loser must leave no account behind — otherwise a registration page that refuses the second person
  # still fills the accounts table with everyone who tried.
  test "of #{@racers} registrations racing, exactly one account is left standing" do
    outcomes = racing(&register/1)

    accounts = TestRepo.aggregate(TestUser, :count)

    assert Enum.count(outcomes, &match?({:ok, _changes}, &1)) == 1
    assert accounts == 1, "#{accounts} accounts survived a race only one should have won"
    assert TestRepo.aggregate(Bootstrap, :count) == 1

    # Counted rather than walked: a comprehension with a pattern filters what does not match out
    # silently, so it holds just as well when nobody lost at all.
    assert Enum.count(outcomes, &match?({:error, :bootstrap, :already_claimed, _done}, &1)) ==
             @racers - 1
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

  defp racing(racer) do
    1..@racers
    |> Task.async_stream(&racer.("racer#{&1}@example.test"), max_concurrency: @racers)
    |> Enum.map(fn
      {:ok, outcome} -> outcome
      {:exit, reason} -> flunk("a racer never finished: #{inspect(reason)}")
    end)
  end

  defp race(email) do
    user = user_fixture(%{email: email})
    TestRepo.insert(Bootstrap.changeset(%Bootstrap{}, %{user_id: user.id}))
  end

  # A different address per racer, deliberately: with one address the accounts table's own unique
  # index refuses seven of them before they ever reach the claim, so what the race would measure is
  # that index rather than the one this test is about.
  defp register(email) do
    Multi.new()
    |> Multi.insert(:account, user_changeset(%{email: email}))
    |> Instance.claim()
    |> TestRepo.transaction()
  end

  defp clear do
    TestRepo.delete_all(Bootstrap)
    TestRepo.delete_all(TestUser)
  end
end
