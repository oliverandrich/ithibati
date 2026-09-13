defmodule Ithibati.Identity.InvitationsRaceTest do
  @moduledoc """
  Eight people opening one invitation link at the same moment. Exactly one account may come of it.

  A test that accepts twice in sequence proves only that the second call read what the first wrote.
  What decides between callers who arrive together is that "not yet accepted" rides the `WHERE` of
  the update itself — and the only way to see that is to have them arrive together.

  Not async and not sandboxed, which `Ithibati.RaceCase` explains.
  """
  use Ithibati.RaceCase

  alias Ecto.Multi
  alias Ithibati.Identity.Invitations
  alias Ithibati.TestInvitation

  @racers 8

  test "of #{@racers} callers accepting one invitation, exactly one gets through" do
    for round <- 1..5 do
      invitation = invite("racer#{round}@example.test")

      outcomes = racing(1..@racers, fn _ -> accept(invitation) end)

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
