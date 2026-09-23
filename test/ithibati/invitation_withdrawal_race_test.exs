defmodule Ithibati.InvitationWithdrawalRaceTest do
  @moduledoc """
  Somebody taking an invitation back while somebody else is redeeming it.

  What this establishes: two callers arriving together never both win. Two winners would leave an
  account whose invitation is gone, which is the one outcome nobody can explain afterwards.

  Measured, because it is worth knowing what this does and does not buy. It does not catch a
  `withdraw/1` that reads the row first and deletes it afterwards: five runs against that shape
  stayed green, because the delete happened to win every time. Widening its window with a
  deliberate `Process.sleep/1` inside the library made it fail on the first run, which is how the
  guard in the real implementation was checked. So this module guards the outcome, not the
  timing — the timing is guaranteed by `withdraw/1` having no window at all, one statement that
  refuses an accepted row while deleting.

  It earns its keep as the thing that would notice a future `withdraw/1` growing a window back.
  """
  use Ithibati.RaceCase

  alias Ecto.Multi
  alias Ithibati.Identity.Invitations
  alias Ithibati.TestInvitation
  alias Ithibati.TestUser

  test "an invitation cannot be both accepted and withdrawn" do
    invitation =
      TestRepo.insert!(
        TestInvitation.changeset(%TestInvitation{}, %{email: "both@example.test", role: :author})
      )

    # `racing_connections/2` holds both callers at a barrier and releases them together, which
    # `racing/2` does not: with two racers one can finish before the other starts, and a window
    # that never opens proves nothing. The roles are taken on arrival, since the barrier hands
    # the same function to both.
    roles = :atomics.new(1, [])

    outcomes =
      racing_connections(2, fn ->
        case :atomics.add_get(roles, 1, 1) do
          1 -> {:accept, accept(invitation)}
          2 -> {:withdraw, Invitations.withdraw(invitation)}
        end
      end)

    won = for {role, {:ok, _}} <- outcomes, do: role

    # Exactly one, in both directions. Two winners would leave an account whose invitation is
    # gone; none would mean the window never opened and this measured nothing.
    assert length(won) == 1, "expected one winner, got #{inspect(outcomes)}"

    assert TestRepo.aggregate(TestUser, :count) == if(won == [:accept], do: 1, else: 0)
  end

  defp clear do
    TestRepo.delete_all(TestInvitation)
    TestRepo.delete_all(TestUser)
  end

  defp accept(invitation) do
    Multi.new()
    |> Multi.insert(:account, TestUser.changeset(%TestUser{}, %{email: invitation.email}))
    |> Invitations.accept(invitation)
    |> TestRepo.transaction()
  end
end
