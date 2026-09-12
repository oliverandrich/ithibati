defmodule Ithibati.Schema.UserTest do
  @moduledoc """
  What `use Ithibati.Schema.User` puts into an account schema, and — the half that matters more —
  what it does not.

  A macro that writes into somebody else's module is the one place where growth is invisible: a
  field added here appears in every consuming application without anyone reading a diff. So the full
  list is written out below, and adding to it has to be a decision rather than a side effect.
  """
  use Ithibati.DataCase, async: true

  alias Ithibati.Schema

  # Everything `Ithibati.TestUser` has that the macro did not put there.
  @consumer_fields [:id, :nickname, :inserted_at, :updated_at]

  describe "what the macro contributes" do
    test "exactly one field, the one the application named" do
      assert TestUser.__schema__(:fields) -- @consumer_fields == [:email]
      assert MemberUser.__schema__(:fields) -- [:id, :inserted_at, :updated_at] == [:username]
    end

    test "one association per table this library owns, and no others" do
      assert TestUser.__schema__(:associations) == [:passkeys, :recovery_codes, :auth_tokens]
    end

    test "the associations reach this library's schemas by the foreign key it declares" do
      for {name, schema} <- [
            passkeys: Ithibati.UserKey,
            recovery_codes: Ithibati.RecoveryCode,
            auth_tokens: Ithibati.UserToken
          ] do
        assoc = TestUser.__schema__(:association, name)

        assert assoc.related == schema
        assert assoc.related_key == :user_id
      end
    end

    # Against a schema that does *not* use the macro, so an injected function nobody asked for shows
    # up as a difference. Filtering down to the expected names first would throw the evidence away
    # before asserting, and the test could then only notice a disappearance.
    test "three functions, and a fourth would have to be a decision" do
      plain = probe("Plain", "")
      injected = probe("Injected", "use Ithibati.Schema.User, identifier: :email")

      assert Enum.sort(injected.__info__(:functions) -- plain.__info__(:functions)) ==
               [__ithibati_identifier__: 0, identifier_changeset: 2, passkey_display_name: 1]
    end
  end

  describe "the identifier an application chooses" do
    # No default, deliberately: a library that never sends mail should not ask for an address by
    # assumption.
    test "has to be chosen — omitting it is a compile error that says so" do
      assert_raise ArgumentError, ~r/needs `identifier:`/, fn ->
        Code.compile_string("""
        defmodule Ithibati.NoIdentifierProbe do
          use Ecto.Schema
          use Ithibati.Schema.User
        end
        """)
      end
    end

    test "has to be a literal atom, and says so rather than reporting itself missing" do
      assert_raise ArgumentError, ~r/must be a literal atom/, fn ->
        probe("Variable", "@f :email\n  use Ithibati.Schema.User, identifier: @f")
      end
    end

    # `true` and `false` are atoms, so without this a schema compiles with a field named `false`.
    test "is not a boolean" do
      assert_raise ArgumentError, ~r/must be a literal atom/, fn ->
        probe("Boolean", "use Ithibati.Schema.User, identifier: true")
      end
    end

    test "is the field the schema declares and the one the library reads" do
      assert TestUser.__ithibati_identifier__() == :email
      assert MemberUser.__ithibati_identifier__() == :username
    end

    test "is trimmed and lowercased whatever it is called" do
      assert TestUser.changeset(%TestUser{}, %{email: "  Someone@Example.TEST "}).changes.email ==
               "someone@example.test"

      assert MemberUser.changeset(%MemberUser{}, %{username: " AdaLovelace "}).changes.username ==
               "adalovelace"
    end

    test "is required" do
      assert %{email: ["can't be blank"]} =
               errors_on(TestUser.changeset(%TestUser{}, %{email: " "}))
    end
  end

  describe "the format, which is optional and the application's" do
    # Without the check this compiles and `validate_format/4` degrades to `String.contains?/2`,
    # which refuses "abc" against "^[a-z]+$" and accepts "x^[a-z]+$y" — wrong in both directions,
    # with nothing to see at compile time.
    test "has to be a regular expression, and a forgotten sigil says so" do
      assert_raise ArgumentError, ~r/did you mean ~r/, fn ->
        probe("Stringly", ~s|use Ithibati.Schema.User, identifier: :email, format: "^[a-z]+$"|)
      end
    end

    # The pattern offered for an address is the one the HTML specification publishes for
    # `<input type=email>`, so what it accepts is wider than a mail transfer agent would and
    # narrower than RFC 5322.
    test "an address schema takes addresses, including ones with no dot in the domain" do
      assert valid?(TestUser, :email, "you@localhost")
      assert valid?(TestUser, :email, "a.b+c@example.co.uk")
      refute valid?(TestUser, :email, "no-at-sign")
      refute valid?(TestUser, :email, "a@-bad.example")
    end

    # A quoted local part is legal RFC 5322 and a hazard as a credential.
    test "an address schema refuses an address with a space in it" do
      refute valid?(TestUser, :email, ~s("a b"@example.com))
    end

    test "a username schema takes usernames and refuses addresses" do
      assert valid?(MemberUser, :username, "adalovelace")
      assert valid?(MemberUser, :username, "ada-lovelace_1")
      refute valid?(MemberUser, :username, "ada@example.test")
      refute valid?(MemberUser, :username, "ab")
    end
  end

  test "the identifier is unique, and a duplicate comes back as an error on the field" do
    {:ok, _} = insert("taken@example.test")

    assert {:error, changeset} = insert("taken@example.test")
    assert %{email: ["has already been taken"]} = errors_on(changeset)
  end

  # Lowercasing is what makes the unique index refuse a capitalisation of a name somebody already
  # has, without a functional index the application would have to remember.
  test "a capitalisation of an identifier somebody has is the same identifier" do
    {:ok, _} = TestRepo.insert(MemberUser.changeset(%MemberUser{}, %{username: "adalovelace"}))

    assert {:error, changeset} =
             TestRepo.insert(MemberUser.changeset(%MemberUser{}, %{username: "AdaLovelace"}))

    assert %{username: ["has already been taken"]} = errors_on(changeset)
  end

  # The documented contract, and the reason it is a fragment rather than a changeset that owns the
  # account: an application pipes it into its own and keeps what it had.
  test "the changeset composes onto one the application has already started" do
    changeset =
      %TestUser{}
      |> Ecto.Changeset.cast(%{nickname: "Ada"}, [:nickname])
      |> TestUser.identifier_changeset(%{email: "ada@example.test"})

    assert changeset.changes == %{nickname: "Ada", email: "ada@example.test"}
  end

  describe "the name a passkey dialog shows" do
    test "is nothing unless the application says otherwise" do
      assert TestUser.passkey_display_name(%TestUser{email: "someone@example.test"}) == nil
    end

    test "is whatever an override answers" do
      assert NamedUser.passkey_display_name(%NamedUser{nickname: "Ada"}) == "Ada"
    end

    test "falls back to the identifier, which the library does rather than the application" do
      assert Schema.User.credential_user(%NamedUser{email: "a@b.test", nickname: nil}) ==
               %{name: "a@b.test", display_name: "a@b.test"}

      assert Schema.User.credential_user(%NamedUser{email: "a@b.test", nickname: "Ada"}) ==
               %{name: "a@b.test", display_name: "Ada"}
    end

    # Read through the generated function, so an account known by a username shows that.
    test "reads whichever field the application chose" do
      assert Schema.User.credential_user(%MemberUser{username: "adalovelace"}) ==
               %{name: "adalovelace", display_name: "adalovelace"}
    end

    test "says what is wrong when handed a struct that is not an account" do
      assert_raise ArgumentError, ~r/does not `use Ithibati.Schema.User`/, fn ->
        Schema.User.credential_user(%Ecto.Changeset{})
      end
    end

    # The first registration on an instance has no account yet, so there is nothing to call an
    # override on. That path takes the identifier itself.
    test "works before an account exists" do
      assert Schema.User.credential_user("first@example.test") ==
               %{name: "first@example.test", display_name: "first@example.test"}
    end
  end

  defp insert(email), do: %TestUser{} |> TestUser.changeset(%{email: email}) |> TestRepo.insert()

  defp valid?(schema, field, value) do
    match?(
      %Ecto.Changeset{valid?: true},
      schema.identifier_changeset(struct(schema), %{field => value})
    )
  end

  # Each probe gets a name of its own: a module compiled twice warns about redefinition.
  defp probe(name, body) do
    source =
      "defmodule Ithibati.Probe" <>
        name <>
        " do\n  use Ecto.Schema\n  " <>
        body <>
        "\n\n  @primary_key {:id, :binary_id, autogenerate: true}\n" <>
        "  schema \"probes\" do\n  end\nend\n"

    [{module, _bytecode} | _] = Code.compile_string(source)
    module
  end
end
