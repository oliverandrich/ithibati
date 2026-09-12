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
    test "exactly one field, and it is named here" do
      assert TestUser.__schema__(:fields) -- @consumer_fields == [:email]
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
  end

  describe "the address" do
    test "is trimmed and lowercased" do
      changeset = Schema.User.email_changeset(%TestUser{}, %{email: "  Someone@Example.TEST "})

      assert changeset.changes.email == "someone@example.test"
    end

    test "is required" do
      changeset = Schema.User.email_changeset(%TestUser{}, %{email: "   "})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    # The pattern is the one the HTML specification publishes for `<input type=email>`, so what it
    # accepts is deliberately wider than a mail transfer agent would and narrower than RFC 5322.
    test "needs an at sign, and nothing else it does not need" do
      assert valid?("you@localhost"), "a self-hosted instance has addresses with no dot in them"
      assert valid?("a.b+c@example.co.uk")
      refute valid?("no-at-sign")
      refute valid?("a@-bad.example")
    end

    # A quoted local part is legal RFC 5322 and a hazard as a credential.
    test "refuses an address with a space in it" do
      refute valid?(~s("a b"@example.com))
    end

    test "is unique, and a duplicate comes back as an error on the field" do
      {:ok, _} = insert("taken@example.test")

      assert {:error, changeset} = insert("taken@example.test")
      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end
  end

  # The documented contract, and the reason it is a fragment rather than a changeset that owns the
  # account: an application pipes it into its own and keeps what it had.
  test "the changeset composes onto one the application has already started" do
    changeset =
      %TestUser{}
      |> Ecto.Changeset.cast(%{nickname: "Ada"}, [:nickname])
      |> Schema.User.email_changeset(%{email: "ada@example.test"})

    assert changeset.changes == %{nickname: "Ada", email: "ada@example.test"}
  end

  describe "the name a passkey dialog shows" do
    test "is nothing unless the application says otherwise" do
      assert TestUser.passkey_display_name(%TestUser{email: "someone@example.test"}) == nil
    end

    test "is whatever an override answers" do
      assert NamedUser.passkey_display_name(%NamedUser{nickname: "Ada"}) == "Ada"
    end

    # The reason the override needs no fallback of its own, and the reason the library derives both
    # fields rather than the caller: an account that has not filled the better name in answers `nil`,
    # which is correct.
    test "falls back to the address, which the library does rather than the application" do
      assert Schema.User.credential_user(%NamedUser{email: "a@b.test", nickname: nil}) ==
               %{name: "a@b.test", display_name: "a@b.test"}

      assert Schema.User.credential_user(%NamedUser{email: "a@b.test", nickname: "Ada"}) ==
               %{name: "a@b.test", display_name: "Ada"}
    end

    # The first registration on an instance has no account yet, so there is nothing to call an
    # override on. That path takes the address itself.
    test "works before an account exists" do
      assert Schema.User.credential_user("first@example.test") ==
               %{name: "first@example.test", display_name: "first@example.test"}
    end
  end

  defp insert(email), do: %TestUser{} |> TestUser.changeset(%{email: email}) |> TestRepo.insert()

  defp valid?(email),
    do:
      match?(
        %Ecto.Changeset{valid?: true},
        Schema.User.email_changeset(%TestUser{}, %{email: email})
      )
end
