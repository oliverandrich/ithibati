defmodule Ithibati.Identity.InvitationsTest do
  @moduledoc """
  Opening a link and accepting what it opens.

  The acceptance is a fragment rather than a function that does the work: the account, its first
  passkey, its recovery codes, the invitation and whatever the application grants all land in one
  transaction or none of them do. So most of what is here composes a multi the way a consumer would
  and then checks both outcomes.
  """
  use Ithibati.DataCase, async: true

  alias Ecto.Multi
  alias Ithibati.Identity.Grant
  alias Ithibati.Identity.Invitations
  alias Ithibati.TestInvitation

  describe "fetch/1" do
    test "answers the pending invitation the token opens" do
      invitation = invite("open@example.test")

      assert %TestInvitation{id: id} = Invitations.fetch(invitation.token)
      assert id == invitation.id
    end

    test "and nothing for a token nobody holds" do
      refute Invitations.fetch("not-a-token")
    end

    test "and nothing for one that was already accepted" do
      invitation = invite("used@example.test")
      accept!(invitation)

      refute Invitations.fetch(invitation.token)
    end

    test "and nothing for one that has run out" do
      invitation = invite("stale@example.test", days: -1)

      refute Invitations.fetch(invitation.token)
    end

    # A token arrives from a URL, so the thing handed over is whatever the router parsed.
    test "and nothing at all for a value that is not a token" do
      refute Invitations.fetch(nil)
    end
  end

  test "account_attrs/1 names the identifier the way both schemas agreed to" do
    invitation = invite("attrs@example.test")

    assert Invitations.account_attrs(invitation) == %{email: "attrs@example.test"}
  end

  describe "accept/2, composed into the caller's transaction" do
    test "marks the invitation and lets the application's own step see it" do
      invitation = invite("compose@example.test")

      assert {:ok, changes} =
               Multi.new()
               |> Multi.insert(:account, user_changeset(Invitations.account_attrs(invitation)))
               |> Grant.with_key_and_codes(stand_in_key())
               |> Invitations.accept(invitation)
               |> Multi.update(:membership, fn %{account: account, invitation: accepted} ->
                 change(account, nickname: to_string(accepted.role))
               end)
               |> TestRepo.transaction()

      assert changes.invitation.accepted_at
      assert TestRepo.get!(TestInvitation, invitation.id).accepted_at

      # The domain field the invitation granted, written from inside the same transaction — which is
      # the whole reason acceptance is a step rather than an event.
      assert TestRepo.get!(TestUser, changes.account.id).nickname == "author"
    end

    # The reason acceptance is a fragment and not a callback: a step that fails after the account
    # exists must take the account with it, and an event fired after the transaction cannot.
    test "and both halves roll back when the application's step fails" do
      invitation = invite("rollback@example.test")

      assert {:error, :membership, :no_seats, _done} =
               Multi.new()
               |> Multi.insert(:account, user_changeset(Invitations.account_attrs(invitation)))
               |> Grant.with_key_and_codes(stand_in_key())
               |> Invitations.accept(invitation)
               |> Multi.run(:membership, fn _repo, _changes -> {:error, :no_seats} end)
               |> TestRepo.transaction()

      refute TestRepo.get!(TestInvitation, invitation.id).accepted_at
      refute TestRepo.get_by(TestUser, email: "rollback@example.test")
    end

    test "and an invitation that was accepted in the meantime takes the account with it" do
      invitation = invite("twice@example.test")
      accept!(invitation)

      assert {:error, :invitation, :invalid_invitation, _done} =
               Multi.new()
               |> Multi.insert(:account, user_changeset(Invitations.account_attrs(invitation)))
               |> Invitations.accept(invitation)
               |> TestRepo.transaction()

      refute TestRepo.get_by(TestUser, email: "twice@example.test")
    end

    # An acceptance form that lets the invitee correct the address is an ordinary thing to build, and
    # this is what stops it from turning an invitation for one person into an account for another.
    test "and refuses an account created under a different address" do
      invitation = invite("addressed@example.test")

      assert {:error, :invitation, :identifier_mismatch, _done} =
               Multi.new()
               |> Multi.insert(:account, user_changeset(%{email: "someone-else@example.test"}))
               |> Invitations.accept(invitation)
               |> TestRepo.transaction()

      refute TestRepo.get!(TestInvitation, invitation.id).accepted_at
      refute TestRepo.get_by(TestUser, email: "someone-else@example.test")
    end

    # A step that is absent is allowed; a step that is there and holds something else is the mistake
    # `Ithibati.Config.account!/1` exists for, and it would otherwise be compared field by field
    # against the invitation.
    test "and refuses a step holding something that is not an account" do
      invitation = invite("guarded@example.test")

      assert_raise ArgumentError, ~r/expected a Ithibati.TestUser/, fn ->
        Multi.new()
        |> Multi.run(:account, fn _repo, _changes -> {:ok, %Ithibati.MemberUser{}} end)
        |> Invitations.accept(invitation)
        |> TestRepo.transaction()
      end
    end

    test "and looks for that account under the step name it was given" do
      invitation = invite("named-step@example.test")

      assert {:error, :invitation, :identifier_mismatch, _done} =
               Multi.new()
               |> Multi.insert(:invitee, user_changeset(%{email: "not-them@example.test"}))
               |> Invitations.accept(invitation, account: :invitee)
               |> TestRepo.transaction()
    end

    test "and one that ran out is refused the same way" do
      invitation = invite("late@example.test", days: -1)

      assert {:error, :invitation, :invalid_invitation, _done} =
               Multi.new()
               |> Invitations.accept(invitation)
               |> TestRepo.transaction()
    end
  end

  describe "the expired ones" do
    test "are the ones nobody accepted in time" do
      stale = invite("gone@example.test", days: -1)
      invite("fresh@example.test")
      # Accepted first and aged afterwards: an invitation that ran out cannot be accepted at all,
      # and this is the row that has to stay out of the list anyway.
      accepted = invite("done@example.test")
      accept!(accepted)
      age(accepted)

      assert Enum.map(Invitations.expired(), & &1.id) == [stale.id]
    end

    test "and delete_expired/0 removes exactly those" do
      invite("gone1@example.test", days: -1)
      invite("gone2@example.test", days: -1)
      kept = invite("kept@example.test")

      assert Invitations.delete_expired() == 2
      assert Enum.map(TestRepo.all(TestInvitation), & &1.id) == [kept.id]
    end
  end

  describe "the pending ones" do
    test "are the ones still open to somebody" do
      open = invite("open@example.test")
      invite("stale@example.test", days: -1)
      accepted = invite("done@example.test")
      accept!(accepted)

      assert Enum.map(Invitations.pending(), & &1.id) == [open.id]
    end

    # The application owns the table and whatever it added to it, so the list it wants is almost
    # never all of them. What the library contributes is the predicate — which has to be the one
    # `fetch/1` uses, or a page shows a link that no longer opens anything.
    test "and pending_query/0 is something the application can narrow" do
      invite("first@example.test")
      wanted = invite("second@example.test")

      narrowed =
        from(i in Invitations.pending_query(), where: i.email == ^"second@example.test")

      assert Enum.map(TestRepo.all(narrowed), & &1.id) == [wanted.id]
    end
  end

  describe "withdrawing one" do
    test "takes back an invitation nobody has accepted" do
      invitation = invite("regret@example.test")

      assert {:ok, _withdrawn} = Invitations.withdraw(invitation)
      assert TestRepo.all(TestInvitation) == []
    end

    # The link stops opening anything, which is the whole point: an invitation withdrawn but
    # still redeemable would be worse than none at all.
    test "and the link it was is no longer one" do
      invitation = invite("regret@example.test")
      token = invitation.token

      assert {:ok, _withdrawn} = Invitations.withdraw(invitation)
      assert Invitations.fetch(token) == nil
    end

    # Checked in the delete itself rather than before it. Reading the row first and deleting
    # afterwards is how a withdrawal removes an invitation somebody accepted in between.
    test "and refuses one that was accepted in the meantime" do
      invitation = invite("quick@example.test")
      accept!(invitation)

      assert {:error, :already_accepted} = Invitations.withdraw(invitation)
      assert [kept] = TestRepo.all(TestInvitation)
      assert kept.accepted_at
    end

    test "and says so for one that is no longer there at all" do
      invitation = invite("gone@example.test")
      TestRepo.delete!(invitation)

      assert {:error, :already_accepted} = Invitations.withdraw(invitation)
    end
  end

  defp invite(email, opts \\ []) do
    TestRepo.insert!(
      TestInvitation.changeset(%TestInvitation{}, %{email: email, role: :author}, opts)
    )
  end

  defp age(invitation) do
    TestRepo.update_all(from(i in TestInvitation, where: i.id == ^invitation.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :day)]
    )
  end

  defp accept!(invitation) do
    {:ok, %{invitation: accepted}} =
      Multi.new() |> Invitations.accept(invitation) |> TestRepo.transaction()

    accepted
  end
end
