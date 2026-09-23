defmodule Ithibati.Identity.InvitationsKeyTest do
  @moduledoc """
  An invitation table whose primary key is not called `id`.

  Not async: it moves `invitation_schema`, which every other module reads.
  """
  use Ithibati.DataCase, async: false

  alias Ecto.Multi
  alias Ithibati.Identity.Invitations
  alias Ithibati.OddInvitation

  setup do
    put_env(:ithibati, invitation_schema: OddInvitation)
  end

  # A query that wrote `id` out by hand would work everywhere except here, which is what this
  # schema exists to say.
  test "is listed and withdrawn like any other" do
    invitation =
      TestRepo.insert!(
        OddInvitation.invitation_changeset(%OddInvitation{}, %{email: "odd@example.test"})
      )

    assert Enum.map(Invitations.pending(), & &1.invitation_id) == [invitation.invitation_id]

    assert {:ok, withdrawn} = Invitations.withdraw(invitation)
    assert withdrawn.invitation_id == invitation.invitation_id
    assert Invitations.pending() == []
  end

  # The struct says which table a withdrawal would write to, so handing over the wrong one has to
  # be refused rather than aimed at the invitation table by whatever id it happens to carry.
  test "and a struct that is not the configured schema is refused" do
    assert_raise ArgumentError, ~r/expected a Ithibati.OddInvitation/, fn ->
      Invitations.withdraw(%Ithibati.TestInvitation{id: Ecto.UUID.generate()})
    end
  end

  test "is found and accepted like any other" do
    invitation =
      TestRepo.insert!(
        OddInvitation.invitation_changeset(%OddInvitation{}, %{email: "odd@example.test"})
      )

    assert found = Invitations.fetch(invitation.token)
    assert found.invitation_id == invitation.invitation_id

    assert {:ok, %{invitation: accepted}} =
             Multi.new()
             |> Multi.insert(:account, user_changeset(Invitations.account_attrs(found)))
             |> Invitations.accept(found)
             |> TestRepo.transaction()

    assert accepted.accepted_at
  end
end
