defmodule IthibatiInvitesWeb.AuthTest do
  @moduledoc """
  The one function this example exists for, driven directly.

  The ceremony either side of it is the library's and is tested there; what is this application's
  is who may start a registration and what the credential is then made into. Both callbacks are
  called the way `Ithibati.Web.PasskeyController` calls them, which is the only way they are ever
  called.
  """
  use IthibatiInvites.DataCase, async: true

  alias Ithibati.Identity.Instance
  alias Ithibati.Identity.Invitations
  alias IthibatiInvites.Accounts.Invitation
  alias IthibatiInvites.Accounts.User
  alias IthibatiInvitesWeb.Auth

  # What `Ithibati.Identity.Passkeys.verify_registration/2` hands the handler, reduced to the two
  # keys `Grant.with_key_and_codes/3` reads. A real credential would prove something about the
  # ceremony; nothing here is about the ceremony.
  defp key_attrs do
    %{key_id: :crypto.strong_rand_bytes(16), public_key: :crypto.strong_rand_bytes(64)}
  end

  # `Gate.log_in/2` renews the session, which raises unless one was fetched.
  defp conn, do: Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})

  defp authorized_conn do
    {:ok, code} = Instance.issue_code()
    {:ok, proof} = Instance.authorize_code(code)
    Plug.Conn.put_session(conn(), :initial_claim_authorization, proof)
  end

  defp claim_instance(username) do
    {:ok, _conn} = Auth.register(authorized_conn(), key_attrs(), username, %{})

    Repo.get_by!(User, username: username)
  end

  defp invite(username, opts \\ []) do
    %Invitation{}
    |> Invitation.changeset(%{"username" => username}, opts)
    |> Repo.insert!()
  end

  test "an unapproved request cannot start or complete the first claim" do
    assert {:ok, _code} = Ithibati.Identity.Instance.issue_code()

    assert {:error, :setup_authorization_required} =
             Auth.registration_subject(conn(), %{"username" => "first_one"})

    assert {:error, :setup_authorization_required} =
             Auth.register(conn(), key_attrs(), "first_one", %{})

    refute Repo.get_by(User, username: "first_one")
  end

  describe "the first account" do
    test "arrives without an invitation, and claims the instance doing it" do
      conn = authorized_conn()
      assert {:ok, "first_one"} = Auth.registration_subject(conn, %{"username" => "first_one"})

      assert {:ok, _conn} = Auth.register(conn, key_attrs(), "first_one", %{})

      assert Repo.get_by(User, username: "first_one")
      refute Ithibati.Identity.Instance.needs_setup?()
    end

    test "a rotated code revokes a challenge that was already authorized" do
      conn = authorized_conn()
      assert {:ok, "first_one"} = Auth.registration_subject(conn, %{"username" => "first_one"})
      assert {:ok, _new_code} = Instance.issue_code()

      assert {:error, :setup_authorization_required} =
               Auth.register(conn, key_attrs(), "first_one", %{})

      assert Instance.needs_setup?()
      refute Repo.get_by(User, username: "first_one")
    end

    test "is the only one: the next person needs an invitation" do
      claim_instance("first_one")

      assert {:error, :invitation_required} =
               Auth.registration_subject(conn(), %{"username" => "second"})
    end

    test "is refused without a username, rather than minting a challenge for nobody" do
      assert {:error, :username_required} = Auth.registration_subject(authorized_conn(), %{})
    end

    # The expensive order to get wrong: approving it here means a passkey dialog, a credential the
    # authenticator then keeps, and only afterwards a refusal.
    test "is refused when the name is one the schema could never store" do
      for value <- ["Alice Smith!", "alice.smith", String.duplicate("a", 31), ""] do
        assert {:error, :invalid_username} =
                 Auth.registration_subject(authorized_conn(), %{"username" => value}),
               "approved #{inspect(value)}"
      end
    end

    test "and the name it approves is the one that will be stored" do
      assert {:ok, "ada"} =
               Auth.registration_subject(authorized_conn(), %{"username" => "  Ada  "})
    end
  end

  describe "an invitation" do
    setup do
      claim_instance("first_one")

      %{invitation: invite("invitee")}
    end

    test "opens a registration for the name it was addressed to", ctx do
      assert {:ok, "invitee"} =
               Auth.registration_subject(conn(), %{"token" => ctx.invitation.token})
    end

    test "creates that account and is spent in the same breath", ctx do
      assert {:ok, _conn} =
               Auth.register(conn(), key_attrs(), "invitee", %{"token" => ctx.invitation.token})

      assert Repo.get_by(User, username: "invitee")
      assert Repo.get!(Invitation, ctx.invitation.id).accepted_at
    end

    test "cannot be spent twice", ctx do
      assert {:ok, _conn} =
               Auth.register(conn(), key_attrs(), "invitee", %{"token" => ctx.invitation.token})

      assert {:error, :invitation_unknown} =
               Auth.register(conn(), key_attrs(), "invitee", %{"token" => ctx.invitation.token})
    end
  end

  # A used link, an expired one and one nobody ever held are the same answer on purpose: anything
  # else tells a guesser which of their guesses was once real.
  describe "a token that opens nothing" do
    setup do
      claim_instance("first_one")

      :ok
    end

    test "is refused when nobody ever held it" do
      assert {:error, :invitation_unknown} =
               Auth.registration_subject(conn(), %{"token" => "not-a-token"})
    end

    test "is refused when it was already accepted" do
      invitation = invite("invitee")
      {:ok, _conn} = Auth.register(conn(), key_attrs(), "invitee", %{"token" => invitation.token})

      assert {:error, :invitation_unknown} =
               Auth.registration_subject(conn(), %{"token" => invitation.token})
    end

    test "is refused when it has expired" do
      invitation = invite("invitee", days: -1)

      assert {:error, :invitation_unknown} =
               Auth.registration_subject(conn(), %{"token" => invitation.token})
    end

    test "is refused when there is no token at all" do
      assert {:error, :invitation_required} = Auth.registration_subject(conn(), %{})
    end
  end

  # The browser sends the whole body again at the verify step, so the token arriving there is the
  # client's word for which invitation this is — while the identifier that travelled with the
  # challenge is this application's. When they disagree, the challenge wins.
  test "the invitation accepted is the one the challenge approved, not the one the second request names" do
    claim_instance("first_one")
    _alice = invite("alice")
    bob = invite("bob")

    assert {:error, :invitation_unknown} =
             Auth.register(conn(), key_attrs(), "alice", %{"token" => bob.token})

    refute Repo.get_by(User, username: "alice")
    refute Repo.get_by(User, username: "bob")
    assert Invitations.fetch(bob.token)
  end

  # `register/4` takes the subject from the session, not from this request, so it is worth asking
  # what it answers for one that should never have got there. "Taken" would be a lie about a name
  # nobody holds — and the two errors come from different places, so only the constraint can say.
  test "a subject the schema refuses is answered as malformed, not as taken" do
    assert {:error, :invalid_username} =
             Auth.register(authorized_conn(), key_attrs(), "Not A Name!", %{})
  end

  # Two invitations may name one person — nothing stops that, and nothing should, since the first
  # acceptance is the one that counts. What the second must not do is answer `verification_failed`,
  # which is what a changeset reaching the controller collapses to.
  test "a name somebody already has is named as such, not collapsed into a generic failure" do
    claim_instance("first_one")
    first = invite("twin")
    second = invite("twin")

    assert {:ok, _conn} = Auth.register(conn(), key_attrs(), "twin", %{"token" => first.token})

    assert {:error, :username_taken} =
             Auth.register(conn(), key_attrs(), "twin", %{"token" => second.token})
  end

  test "a registration with no invitation is refused even if one was approved earlier" do
    claim_instance("first_one")
    invitation = invite("invitee")

    assert {:ok, "invitee"} = Auth.registration_subject(conn(), %{"token" => invitation.token})

    assert {:error, :invitation_unknown} = Auth.register(conn(), key_attrs(), "invitee", %{})

    refute Repo.get_by(User, username: "invitee")
  end
end
