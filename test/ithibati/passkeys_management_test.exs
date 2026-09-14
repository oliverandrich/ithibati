defmodule Ithibati.Identity.PasskeysManagementTest do
  @moduledoc """
  What an account can do with the credentials it already has.

  Async, unlike the other two passkey modules: those are serial because they move `wax_`'s
  application environment, and nothing here goes near the ceremony.

  The refusals these tests are mostly about are `add_key/2`'s and `delete_key/2`'s. What happens when two passkeys are
  deleted at the same moment is `Ithibati.Identity.PasskeysRaceTest`'s, because a sequence cannot
  show it.
  """
  use Ithibati.DataCase, async: true

  alias Ithibati.Identity.Passkeys
  alias Ithibati.UserKey

  describe "add_key/2" do
    test "enrols a credential on an account that already has one" do
      account = user_fixture()
      first = key_fixture(account, %{label: "Laptop"})

      assert {:ok, second} =
               Passkeys.add_key(account, Passkeys.key_attrs(stand_in_key(), "Phone"))

      assert second.label == "Phone"
      assert second.user_id == account.id
      assert Enum.map(Passkeys.list_keys(account), & &1.id) == [first.id, second.id]
    end

    # `registration_options/3` puts the account's credentials in `excludeCredentials`, so a browser
    # that honours it never offers one twice. The unique index is what answers for a client that
    # does not, and this is the word it answers with.
    test "and refuses the same authenticator twice" do
      account = user_fixture()
      material = stand_in_key()
      {:ok, _} = Passkeys.add_key(account, Passkeys.key_attrs(material, "Laptop"))

      assert {:error, :already_enrolled} =
               Passkeys.add_key(account, Passkeys.key_attrs(material, "Laptop again"))

      assert length(Passkeys.list_keys(account)) == 1
    end

    # A credential identifies an authenticator, not a person, so the same one on two accounts is
    # the same collision — and it must not read as "yours".
    test "and refuses one another account already enrolled" do
      material = stand_in_key()
      {:ok, _} = Passkeys.add_key(user_fixture(), Passkeys.key_attrs(material, "Theirs"))

      assert {:error, :already_enrolled} =
               Passkeys.add_key(user_fixture(), Passkeys.key_attrs(material, "Mine"))
    end

    # The read side short-circuits a credential id past this without querying, so a row stored
    # past it is a passkey no sign-in can ever reach.
    test "and refuses a credential id longer than one this library could ever look up" do
      account = user_fixture()
      too_long = :crypto.strong_rand_bytes(1024)
      attrs = Passkeys.key_attrs(%{key_id: too_long, public_key: "x"}, "Oversized")

      assert_raise Ecto.InvalidChangesetError, fn -> Passkeys.add_key(account, attrs) end
      assert Passkeys.list_keys(account) == []
    end

    # The refusal has to leave the surrounding transaction usable, and only a caller's own
    # transaction can show it: the sandbox wraps every statement in a savepoint of its own until
    # one is open, which would hide a missing savepoint here behind the test harness.
    test "and refuses without taking a caller's transaction down with it" do
      account = user_fixture()
      material = stand_in_key()
      {:ok, _} = Passkeys.add_key(account, Passkeys.key_attrs(material, "Laptop"))

      assert {:ok, :carried_on} =
               TestRepo.transaction(fn ->
                 assert {:error, :already_enrolled} =
                          Passkeys.add_key(account, Passkeys.key_attrs(material, "Again"))

                 {:ok, _} = Passkeys.add_key(account, Passkeys.key_attrs(stand_in_key(), "Phone"))
                 :carried_on
               end)

      assert length(Passkeys.list_keys(account)) == 2
    end
  end

  describe "list_keys/1" do
    test "answers the account's own credentials, oldest first" do
      account = user_fixture()
      first = key_fixture(account, %{label: "Laptop"})
      second = key_fixture(account, %{label: "Phone"})
      key_fixture(user_fixture(), %{label: "Somebody else's"})

      assert Enum.map(Passkeys.list_keys(account), & &1.id) == [first.id, second.id]
    end

    test "and nothing for an account that has none" do
      assert Passkeys.list_keys(user_fixture()) == []
    end

    # Equal sort keys have no defined order in Postgres, so without a tiebreaker a list of rows that
    # share an `inserted_at` can come back either way round between two renders.
    test "and orders a tie by id, so the list does not move between renders" do
      account = user_fixture()
      for label <- ~w(a b c d e f g h), do: key_fixture(account, %{label: label})

      # The tie is made here rather than hoped for: `UserKey.changeset/2` does not cast
      # `inserted_at`, so four fixtures are four different microseconds and the ordering this test
      # is about would never be reached.
      TestRepo.update_all(from(k in UserKey, where: k.user_id == ^account.id),
        set: [inserted_at: DateTime.utc_now()]
      )

      ids = Enum.map(Passkeys.list_keys(account), & &1.id)

      assert ids == Enum.sort(ids)
    end

    test "and refuses a struct that is not the configured account schema" do
      assert_raise ArgumentError, ~r/expected a Ithibati.TestUser/, fn ->
        Passkeys.list_keys(%MemberUser{})
      end
    end
  end

  describe "rename_key/3" do
    test "gives the key the name a person chose" do
      account = user_fixture()
      key = key_fixture(account, %{label: "Chrome on Linux"})

      assert {:ok, renamed} = Passkeys.rename_key(account, key.id, "  My work laptop  ")

      assert renamed.label == "My work laptop"
      assert TestRepo.get!(UserKey, key.id).label == "My work laptop"
    end

    test "and falls back to a name rather than leaving the list with a blank row" do
      account = user_fixture()
      key = key_fixture(account, %{label: "Chrome on Linux"})

      assert {:ok, renamed} = Passkeys.rename_key(account, key.id, "   ")

      assert renamed.label == "Passkey"
    end

    test "and cuts a name too long for a list to show" do
      account = user_fixture()
      key = key_fixture(account)

      assert {:ok, renamed} = Passkeys.rename_key(account, key.id, String.duplicate("x", 400))

      assert String.length(renamed.label) == UserKey.label_max()
    end

    # The account is in the `WHERE` of the update, so this is a property of the statement rather
    # than of a validation somebody could drop — and the key it names is left exactly as it was.
    test "and cannot reach a key belonging to somebody else" do
      account = user_fixture()
      stranger = user_fixture()
      key = key_fixture(stranger, %{label: "Their phone"})

      assert Passkeys.rename_key(account, key.id, "Mine now") == {:error, :not_found}

      untouched = TestRepo.get!(UserKey, key.id)
      assert untouched.label == "Their phone"
      assert untouched.user_id == stranger.id
    end

    test "and answers the same for a key that does not exist" do
      account = user_fixture()

      assert Passkeys.rename_key(account, Ecto.UUID.generate(), "Nothing") == {:error, :not_found}
    end

    # The id comes from a route a person can type into, and `binary_id` raises rather than matching
    # nothing — so without a guard a hand-edited address is a 500 where the answer is a refusal.
    test "and refuses an id that is not one, rather than raising" do
      account = user_fixture()

      assert Passkeys.rename_key(account, "not-a-uuid", "Nothing") == {:error, :not_found}
      assert Passkeys.rename_key(account, nil, "Nothing") == {:error, :not_found}
    end

    # A form posting `name[]=x` hands over a list, and the enrolment path answers the fallback for a
    # value it cannot use rather than failing the write.
    test "and falls back for a name that is not a string at all" do
      account = user_fixture()
      key = key_fixture(account, %{label: "Chrome on Linux"})

      assert {:ok, renamed} = Passkeys.rename_key(account, key.id, ["Mine"])

      assert renamed.label == "Passkey"
    end
  end

  describe "delete_key/2" do
    test "removes the one it was given" do
      account = user_fixture()
      going = key_fixture(account, %{label: "Old phone"})
      staying = key_fixture(account, %{label: "Laptop"})

      assert {:ok, deleted} = Passkeys.delete_key(account, going.id)

      assert deleted.id == going.id
      assert Enum.map(Passkeys.list_keys(account), & &1.id) == [staying.id]
    end

    # An account left with no passkey can still be reached by recovery code, so this is not a
    # lockout on its own — but it is the step that makes one possible, and the person taking it is
    # rarely the person who will need the codes.
    test "and refuses the last one, which is still there afterwards" do
      account = user_fixture()
      only = key_fixture(account)

      assert Passkeys.delete_key(account, only.id) == {:error, :last_key}

      assert Enum.map(Passkeys.list_keys(account), & &1.id) == [only.id]
    end

    # Told apart from the refusal above on purpose: hearing "that is your last one" about a key that
    # was never theirs sends somebody hunting for a device they do not have.
    test "and answers :not_found for a key belonging to somebody else, which survives" do
      account = user_fixture()
      stranger = user_fixture()
      key_fixture(account)
      theirs = key_fixture(stranger)

      assert Passkeys.delete_key(account, theirs.id) == {:error, :not_found}

      assert TestRepo.get(UserKey, theirs.id)
    end

    test "and the same for a key that does not exist" do
      account = user_fixture()
      key_fixture(account)

      assert Passkeys.delete_key(account, Ecto.UUID.generate()) == {:error, :not_found}
    end

    # A consumer with a recovery route of its own says so, and the library stops deciding for it.
    test "and lets the last one go when the application says it may" do
      account = user_fixture()
      only = key_fixture(account)

      assert {:ok, deleted} = Passkeys.delete_key(account, only.id, last: :allow)

      assert deleted.id == only.id
      assert Passkeys.list_keys(account) == []
    end

    test "and still cannot reach somebody else's key that way" do
      account = user_fixture()
      theirs = key_fixture(user_fixture())

      assert Passkeys.delete_key(account, theirs.id, last: :allow) == {:error, :not_found}

      assert TestRepo.get(UserKey, theirs.id)
    end

    test "and refuses an option value it does not know, rather than guessing" do
      account = user_fixture()
      key = key_fixture(account)

      assert_raise ArgumentError, ~r/last: must be :refuse or :allow/, fn ->
        Passkeys.delete_key(account, key.id, last: true)
      end
    end

    # Refused before the transaction opens, so nothing is locked on the way to saying no.
    test "and refuses an id that is not one, rather than raising" do
      account = user_fixture()
      key_fixture(account)

      assert Passkeys.delete_key(account, "not-a-uuid") == {:error, :not_found}
      assert Passkeys.delete_key(account, nil) == {:error, :not_found}
    end
  end
end
