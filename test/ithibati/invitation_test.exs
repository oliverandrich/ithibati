defmodule Ithibati.Schema.InvitationTest do
  @moduledoc """
  The macro an application puts on its own invitation schema.

  Same arrangement as `Ithibati.Schema.User` and tested the same way: what it injects, what it
  refuses at compile time, and the one thing the changeset does that a hand-written one would get
  wrong — minting the secret exactly once and keeping only its digest.
  """
  use Ithibati.DataCase, async: true

  alias Ithibati.Identity.Secrets
  alias Ithibati.TestInvitation

  describe "what the macro injects" do
    test "the invitee's identifier, the digest, the two timestamps and the virtual token" do
      fields = TestInvitation.__schema__(:fields)

      for field <- [:email, :token_hash, :expires_at, :accepted_at], do: assert(field in fields)

      # Virtual fields are not in `:fields` at all, which is exactly what makes it the safe place to
      # put a secret: nothing selects it, nothing writes it.
      refute :token in fields
      assert :token in TestInvitation.__schema__(:virtual_fields)
    end

    test "and answers what it was told" do
      assert TestInvitation.__ithibati_invitation__(:identifier) == :email
      assert TestInvitation.__ithibati_invitation__(:constraint) == nil
      assert TestInvitation.__ithibati_invitation__(:unique_index) == true
    end
  end

  describe "the changeset" do
    test "mints a token, keeps only its digest and hands the plaintext back once" do
      changeset =
        TestInvitation.changeset(%TestInvitation{}, %{email: "a@example.test", role: :author})

      assert {:ok, invitation} = TestRepo.insert(changeset)
      assert is_binary(invitation.token)
      assert invitation.token_hash == Secrets.digest(invitation.token)

      # The second read is the one a consumer gets from then on, and it has no token in it.
      assert TestRepo.get!(TestInvitation, invitation.id).token == nil
    end

    test "normalises the identifier the way the account schema does" do
      changeset =
        TestInvitation.changeset(%TestInvitation{}, %{email: "  A@Example.TEST ", role: :author})

      assert get_change(changeset, :email) == "a@example.test"
    end

    test "expires in a week unless told otherwise" do
      week =
        TestInvitation.changeset(%TestInvitation{}, %{email: "b@example.test", role: :author})

      day =
        TestInvitation.changeset(%TestInvitation{}, %{email: "c@example.test", role: :author},
          days: 1
        )

      assert_in_delta DateTime.diff(get_change(week, :expires_at), DateTime.utc_now()),
                      7 * 86_400,
                      5

      assert_in_delta DateTime.diff(get_change(day, :expires_at), DateTime.utc_now()), 86_400, 5
    end

    test "does not mint a second token when an existing invitation is changed" do
      invitation =
        TestRepo.insert!(
          TestInvitation.changeset(%TestInvitation{}, %{email: "d@example.test", role: :author})
        )

      changed = TestInvitation.changeset(invitation, %{role: :admin})

      assert get_change(changed, :token) == nil
      assert get_change(changed, :token_hash) == nil
      assert get_change(changed, :expires_at) == nil
    end

    test "refuses an identifier that does not match the format it was given" do
      changeset =
        TestInvitation.changeset(%TestInvitation{}, %{email: "not-an-address", role: :author})

      assert %{email: ["has invalid format"]} = errors_on(changeset)
    end

    # The same cap the account changeset applies, because it is the same value under the same name:
    # an invitation to something no account can be called is a link that fails at the very end.
    test "refuses an identifier longer than an account may carry" do
      long = String.duplicate("a", 243) <> "@example.test"

      assert %{email: ["should be at most 254 character(s)"]} =
               errors_on(
                 TestInvitation.changeset(%TestInvitation{}, %{email: long, role: :author})
               )
    end

    # An invitation nobody got round to is extended rather than reissued, so the link that was sent
    # keeps working.
    test "moves the expiry of an existing invitation when told a number of days" do
      invitation =
        TestRepo.insert!(
          TestInvitation.changeset(%TestInvitation{}, %{email: "e@example.test", role: :author})
        )

      extended = TestInvitation.changeset(invitation, %{}, days: 30)

      assert_in_delta DateTime.diff(get_change(extended, :expires_at), DateTime.utc_now()),
                      30 * 86_400,
                      5

      assert get_change(extended, :token_hash) == nil
    end

    # The accounts table's unique index is what makes this impossible rather than merely refused;
    # this is the half that says so before anybody is sent a link.
    test "refuses an address that already has an account" do
      user_fixture(%{email: "taken@example.test"})

      changeset =
        TestInvitation.changeset(%TestInvitation{}, %{email: "Taken@example.test", role: :author})

      assert %{email: ["already has an account"]} = errors_on(changeset)
    end
  end

  describe "what it refuses at compile time" do
    test "a schema that uses the macro and never calls it inside the schema block" do
      assert_raise ArgumentError, ~r/never calls ithibati_invitation\/0/, fn ->
        defmodule Forgetful do
          use Ecto.Schema
          use Ithibati.Schema.Invitation, identifier: :email

          schema "invitations" do
          end
        end
      end
    end

    test "a schema that defines a function the macro generates" do
      assert_raise ArgumentError, ~r/defines invitation_changeset\/3/, fn ->
        defmodule Shadowing do
          use Ecto.Schema
          use Ithibati.Schema.Invitation, identifier: :email

          schema "invitations" do
            ithibati_invitation()
          end

          def invitation_changeset(_invitation, _attrs, _opts), do: :mine
        end
      end
    end

    # The consumer is looking at an invitation schema, so being told about accounts sends them to the
    # wrong macro's documentation.
    test "a missing identifier, named as the macro the consumer actually wrote" do
      assert_raise ArgumentError, ~r/use Ithibati.Schema.Invitation needs `identifier:`/, fn ->
        defmodule Anonymous do
          use Ecto.Schema
          use Ithibati.Schema.Invitation

          schema "invitations" do
            ithibati_invitation()
          end
        end
      end
    end

    test "options that are not a literal keyword list" do
      assert_raise ArgumentError, ~r/takes a literal keyword list/, fn ->
        defmodule Computed do
          use Ecto.Schema
          use Ithibati.Schema.Invitation, Application.get_env(:ithibati, :nope)

          schema "invitations" do
            ithibati_invitation()
          end
        end
      end
    end
  end
end
