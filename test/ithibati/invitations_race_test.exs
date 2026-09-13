defmodule Ithibati.Identity.InvitationsRaceTest do
  @moduledoc """
  Eight people opening one invitation link at the same moment. Exactly one account may come of it.

  A test that accepts twice in sequence proves only that the second call read what the first wrote.
  What decides between callers who arrive together is that "not yet accepted" rides the `WHERE` of
  the update itself — and the only way to see that is to have them arrive together.

  Not async and not sandboxed, for the same reason as `Ithibati.Identity.RecoveryCodesRaceTest`: a
  rollback per test would mean a single connection and no race to lose.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Multi
  alias Ithibati.Identity.Invitations
  alias Ithibati.TestInvitation
  alias Ithibati.TestRepo

  @racers 8

  setup_all do
    pool = TestRepo.config()[:pool_size]

    assert pool >= @racers,
           "pool_size is #{pool}, so only that many of #{@racers} racers can be in flight at once"

    Sandbox.mode(TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)
  end

  setup do
    on_exit(&clear/0)
  end

  test "of #{@racers} callers accepting one invitation, exactly one gets through" do
    for round <- 1..5 do
      invitation = invite("racer#{round}@example.test")

      outcomes =
        1..@racers
        |> Task.async_stream(fn _ -> accept(invitation) end, max_concurrency: @racers)
        |> Enum.map(fn
          {:ok, outcome} -> outcome
          {:exit, reason} -> flunk("a racer never finished: #{inspect(reason)}")
        end)

      won = Enum.count(outcomes, &match?({:ok, _changes}, &1))

      assert won == 1, "round #{round} had #{won} winners"
      assert TestRepo.get!(TestInvitation, invitation.id).accepted_at

      clear()
    end
  end

  # No account step, and that is the point rather than a shortcut. A real acceptance inserts the
  # account under the invitation's own address, so every racer but one would be refused by the unique
  # index on that column *before* reaching the claim — and the test would then be green whatever the
  # claim does. What is being measured is the claim, so nothing else in the transaction may be able
  # to refuse a racer. That the account rolls back with a lost claim is `Ithibati.Identity.
  # InvitationsTest`'s to prove, where there is no race to confuse it.
  defp accept(invitation) do
    Multi.new()
    |> Invitations.accept(invitation)
    |> TestRepo.transaction()
  end

  defp invite(email) do
    TestRepo.insert!(TestInvitation.changeset(%TestInvitation{}, %{email: email, role: :author}))
  end

  defp clear, do: TestRepo.delete_all(TestInvitation)
end
