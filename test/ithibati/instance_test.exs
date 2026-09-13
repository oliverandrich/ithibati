defmodule Ithibati.Identity.InstanceTest do
  @moduledoc """
  Setting an instance up once, and asking whether it still needs it.

  What happens when two people try at the same moment is `Ithibati.BootstrapTest`'s, which has the
  connections to let them arrive together.
  """
  use Ithibati.DataCase, async: true

  alias Ecto.Multi
  alias Ithibati.Bootstrap
  alias Ithibati.Identity.Grant
  alias Ithibati.Identity.Instance

  describe "needs_setup?/0" do
    test "is true while nobody has set the instance up" do
      assert Instance.needs_setup?()
    end

    test "and false once somebody has" do
      claim!()

      refute Instance.needs_setup?()
    end

    # The row is what answers, not the account: deleting whoever set the instance up leaves it set
    # up, which is the whole reason this is a table and not a flag.
    test "and stays false when the account that did it is gone" do
      account = claim!()
      TestRepo.delete!(account)

      refute Instance.needs_setup?()
    end
  end

  describe "claim/2" do
    test "records the account the transaction created" do
      assert {:ok, changes} =
               Multi.new()
               |> Multi.insert(:account, user_changeset())
               |> Instance.claim()
               |> TestRepo.transaction()

      assert changes.bootstrap.user_id == changes.account.id
      assert changes.bootstrap.claimed
    end

    # In the order the documentation recommends: a refused claim then never mints recovery codes
    # that a rolled-back transaction would leave in `changes_so_far` in plaintext.
    test "and composes beside the grant, so a first account arrives with its credentials" do
      assert {:ok, changes} =
               Multi.new()
               |> Multi.insert(:account, user_changeset())
               |> Instance.claim()
               |> Grant.with_key_and_codes(stand_in_key())
               |> TestRepo.transaction()

      assert changes.bootstrap.user_id == changes.account.id
      assert changes.passkey.user_id == changes.account.id
      assert length(changes.recovery_codes) == 12
    end

    # The property that makes a registration page a one-time page rather than a warning: the second
    # attempt does not leave an account behind.
    test "and refuses a second attempt, taking that account with it" do
      claim!()

      assert {:error, :bootstrap, :already_claimed, _done} =
               Multi.new()
               |> Multi.insert(:account, user_changeset(%{email: "second@example.test"}))
               |> Instance.claim()
               |> TestRepo.transaction()

      refute TestRepo.get_by(TestUser, email: "second@example.test")
      assert TestRepo.aggregate(Bootstrap, :count) == 1
    end

    test "and reads the account from the step it was told to" do
      assert {:ok, changes} =
               Multi.new()
               |> Multi.insert(:founder, user_changeset())
               |> Instance.claim(account: :founder)
               |> TestRepo.transaction()

      assert changes.bootstrap.user_id == changes.founder.id
    end

    test "and refuses a step holding something that is not an account" do
      assert_raise ArgumentError, ~r/expected a Ithibati.TestUser/, fn ->
        Multi.new()
        |> Multi.run(:account, fn _repo, _changes -> {:ok, %MemberUser{}} end)
        |> Instance.claim()
        |> TestRepo.transaction()
      end
    end

    # The row records who set the instance up, so composing this without an account is a mistake
    # rather than a choice — unlike `Invitations.accept/3`, which is allowed to stand alone.
    test "and says which step it looked for when there is none" do
      assert_raise ArgumentError,
                   ~r/no step named :account in this multi.*Steps so far: \[\]/s,
                   fn ->
                     Multi.new() |> Instance.claim() |> TestRepo.transaction()
                   end
    end
  end

  defp claim! do
    {:ok, %{account: account}} =
      Multi.new()
      |> Multi.insert(:account, user_changeset())
      |> Instance.claim()
      |> TestRepo.transaction()

    account
  end
end
