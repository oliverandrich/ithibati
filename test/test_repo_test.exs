defmodule Ithibati.TestRepoTest do
  @moduledoc """
  The plumbing, asserted once: a repo that connects, a migration that ran, and a sandbox that rolls
  back. Every later test in this library rests on all three, and when one of them is wrong it is
  worth failing here rather than inside whatever test happened to run first.
  """
  use Ithibati.DataCase, async: true

  # One value, because the pair below only checks anything while both halves use the same address.
  @reused_email "collides@example.test"

  test "a row written through the repo comes back" do
    {:ok, user} = insert("someone@example.test")

    assert %TestUser{email: "someone@example.test"} = TestRepo.get!(TestUser, user.id)
  end

  # The rollback is invisible when it works, so each half states it as a fact it can check alone: a
  # row that outlived its test would be counted here, and would then collide on the unique index.
  test "the sandbox rolls back, so the same address is free again (1 of 2)" do
    assert TestRepo.aggregate(TestUser, :count) == 0
    assert {:ok, _user} = insert(@reused_email)
  end

  test "the sandbox rolls back, so the same address is free again (2 of 2)" do
    assert TestRepo.aggregate(TestUser, :count) == 0
    assert {:ok, _user} = insert(@reused_email)
  end

  defp insert(email), do: %TestUser{} |> TestUser.changeset(%{email: email}) |> TestRepo.insert()
end
