defmodule Ithibati.BootstrapTest do
  @moduledoc """
  An instance can be set up exactly once, driven concurrently.

  Asserting that the unique index exists would prove nothing about what it is for. The index is what
  decides between callers who all try, so eight of them try at once and exactly one survives.

  Twice, because the two prove different things: the first races the index itself, and would still
  hold if `Ithibati.Identity.Instance` were deleted; the second races the path an application takes
  and adds what only that path can lose — an account left behind by a caller who was refused.

  Not async and not sandboxed, which `Ithibati.RaceCase` explains.
  """
  use Ithibati.RaceCase

  import Ithibati.DataCase, only: [user_changeset: 1, user_fixture: 1]

  alias Ecto.Multi
  alias Ithibati.Bootstrap
  alias Ithibati.Identity.Instance
  alias Ithibati.TestUser

  @racers 8

  test "of #{@racers} accounts racing to set the instance up, one wins and the rest are told why" do
    outcomes = racing(1..@racers, &race("racer#{&1}@example.test"))

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
    outcomes = racing(1..@racers, &register("racer#{&1}@example.test"))

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
