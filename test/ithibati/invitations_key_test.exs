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
    configured = Application.fetch_env(:ithibati, :invitation_schema)
    Application.put_env(:ithibati, :invitation_schema, OddInvitation)

    on_exit(fn ->
      case configured do
        {:ok, value} -> Application.put_env(:ithibati, :invitation_schema, value)
        :error -> Application.delete_env(:ithibati, :invitation_schema)
      end
    end)
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
