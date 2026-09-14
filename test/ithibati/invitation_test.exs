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

    # The sentence above is this library's wording and an application is expected to replace it, so
    # there has to be something to match on that is not the sentence. Without it a consumer telling
    # "already has an account" apart from a format error has to string-compare English that this
    # library may reword.
    test "and says so in a way that does not require reading the English" do
      user_fixture(%{email: "taken@example.test"})

      changeset =
        TestInvitation.changeset(%TestInvitation{}, %{email: "taken@example.test", role: :author})

      assert {"already has an account", opts} = changeset.errors[:email]
      assert opts[:validation] == :unclaimed
    end
  end

  describe "the index options" do
    test "a constraint name arrives" do
      body = """
      @index_name :invitations_token_hash_house
      use Ithibati.Schema.Invitation, identifier: :email, constraint_name: @index_name
      """

      module = probe("AttributeConstraintInvitation", body, inside: "ithibati_invitation()")

      assert module.__ithibati_invitation__(:constraint) == :invitations_token_hash_house
    end

    test "and so does an opt-out" do
      body = """
      @make_it false
      use Ithibati.Schema.Invitation, identifier: :email, unique_index: @make_it
      """

      module = probe("AttributeOptOutInvitation", body, inside: "ithibati_invitation()")

      refute module.__ithibati_invitation__(:unique_index)
    end

    # Both accidents the attribute form makes reachable, on this macro too: a misspelled name is
    # `nil` with only a warning.
    test "one that arrived as nil says where to look, for either option" do
      assert_raise ArgumentError, ~r/misspelled module attribute/, fn ->
        probe(
          "NilConstraintInvitation",
          "use Ithibati.Schema.Invitation, identifier: :email, constraint_name: nil",
          inside: "ithibati_invitation()"
        )
      end

      assert_raise ArgumentError, ~r/misspelled module attribute/, fn ->
        probe(
          "NilIndexInvitation",
          "use Ithibati.Schema.Invitation, identifier: :email, unique_index: nil",
          inside: "ithibati_invitation()"
        )
      end
    end
  end

  # An invitation reads `format:` through the same module an account does, so it takes the same
  # shapes — a named pattern among them.
  describe "a format given as a module attribute" do
    test "compiles and is applied" do
      body = """
      @address ~r/\\A[a-z]+@example\\.test\\z/
      use Ithibati.Schema.Invitation, identifier: :email, format: @address
      """

      module = probe("AttributeInvitation", body, inside: "ithibati_invitation()")

      assert %{valid?: true} =
               module.invitation_changeset(struct(module), %{email: "ada@example.test"})

      assert %{valid?: false} =
               module.invitation_changeset(struct(module), %{email: "ada@elsewhere.test"})
    end
  end

  describe "what it refuses at compile time" do
    # The same accident as a forgotten sigil, and reachable from the shape the README now shows: a
    # misspelled attribute is `nil` with only a warning, and would mean no pattern at all.
    test "a format: that arrived as nil, where leaving it out is fine" do
      assert_raise ArgumentError, ~r/misspelled module attribute/, fn ->
        probe("NilFormat", "use Ithibati.Schema.Invitation, identifier: :email, format: nil",
          inside: "ithibati_invitation()"
        )
      end

      formatless =
        probe("NoFormat", "use Ithibati.Schema.Invitation, identifier: :email",
          inside: "ithibati_invitation()"
        )

      assert %{valid?: true} =
               formatless.invitation_changeset(struct(formatless), %{email: "anything at all"})
    end

    test "a schema that uses the macro and never calls it inside the schema block" do
      assert_raise ArgumentError, ~r/never calls ithibati_invitation\/0/, fn ->
        probe("Forgetful", "use Ithibati.Schema.Invitation, identifier: :email")
      end
    end

    test "a schema that defines a function the macro generates" do
      assert_raise ArgumentError, ~r/defines invitation_changeset\/3/, fn ->
        probe("Shadowing", "use Ithibati.Schema.Invitation, identifier: :email",
          inside: "ithibati_invitation()",
          after_schema: "def invitation_changeset(_invitation, _attrs, _opts), do: :mine"
        )
      end
    end

    # The consumer is looking at an invitation schema, so being told about accounts sends them to the
    # wrong macro's documentation.
    test "a missing identifier, named as the macro the consumer actually wrote" do
      assert_raise ArgumentError, ~r/use Ithibati.Schema.Invitation needs `identifier:`/, fn ->
        probe("Anonymous", "use Ithibati.Schema.Invitation", inside: "ithibati_invitation()")
      end
    end

    test "options that are not a literal keyword list" do
      assert_raise ArgumentError, ~r/takes a literal keyword list/, fn ->
        probe(
          "Computed",
          "use Ithibati.Schema.Invitation, Application.get_env(:ithibati, :nope)",
          inside: "ithibati_invitation()"
        )
      end
    end
  end
end
