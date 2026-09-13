defmodule Ithibati.Identity.GrantTest do
  @moduledoc """
  The fragment an application composes into its own transaction, driven the way one would: with a
  step of the application's own on either side of it.
  """
  use Ithibati.DataCase, async: true

  alias Ecto.Multi
  alias Ithibati.Identity.Grant
  alias Ithibati.Identity.Passkeys
  alias Ithibati.Identity.RecoveryCodes
  alias Ithibati.RecoveryCode
  alias Ithibati.UserKey

  # Through the library's own builder, so these tests assert against the shape it produces rather
  # than one assembled here — and with stand-in key material, because nothing in this module checks
  # a signature.
  defp key_attrs do
    Passkeys.key_attrs(
      %{
        key_id: :crypto.strong_rand_bytes(16),
        public_key: :erlang.term_to_binary(%{stand_in: :crypto.strong_rand_bytes(32)})
      },
      "A phone"
    )
  end

  defp grant(opts \\ []) do
    {attrs, opts} = Keyword.pop(opts, :attrs, key_attrs())

    Multi.new()
    |> Multi.insert(:account, user_changeset())
    |> Grant.with_key_and_codes(attrs, opts)
    |> TestRepo.transaction()
  end

  defp grant_for(account) do
    Multi.new()
    |> Multi.run(:account, fn _repo, _changes -> {:ok, account} end)
    |> Grant.with_key_and_codes(key_attrs())
    |> TestRepo.transaction()
  end

  describe "with_key_and_codes/3" do
    test "provisions the account, its first passkey and its codes in one go" do
      assert {:ok, changes} =
               grant()

      account = changes.account

      assert changes.passkey.user_id == account.id
      assert changes.passkey.label == "A phone"
      assert length(changes.recovery_codes) == 12
      assert RecoveryCodes.remaining(account) == 12
    end

    # The plaintext exists exactly once, in this result. A caller that does not read it out has no
    # way back to it, which is the property the digests are for.
    test "and the codes it answers are the ones that work" do
      {:ok, changes} =
        grant()

      assert {:ok, account, _fresh} = RecoveryCodes.redeem(hd(changes.recovery_codes))
      assert account.id == changes.account.id
    end

    test "takes the name of the step that made the account" do
      assert {:ok, changes} =
               Multi.new()
               |> Multi.insert(:person, user_changeset())
               |> Grant.with_key_and_codes(key_attrs(), account: :person)
               |> TestRepo.transaction()

      assert changes.passkey.user_id == changes.person.id
    end

    test "and says so when there is no such step" do
      assert_raise ArgumentError, ~r/no step named :account in this multi/, fn ->
        Multi.new()
        |> Multi.insert(:person, user_changeset())
        |> Grant.with_key_and_codes(key_attrs())
        |> TestRepo.transaction()
      end
    end

    test "issues as many codes as the application asked for" do
      {:ok, changes} =
        grant(count: 4)

      assert length(changes.recovery_codes) == 4
    end

    test "and rolls the account back when the application's own step fails" do
      assert {:error, :membership, :nope, _changes} =
               Multi.new()
               |> Multi.insert(:account, user_changeset(%{email: "rolled-back@example.test"}))
               |> Grant.with_key_and_codes(key_attrs())
               |> Multi.run(:membership, fn _repo, _changes -> {:error, :nope} end)
               |> TestRepo.transaction()

      assert TestRepo.aggregate(TestUser, :count) == 0
      assert TestRepo.aggregate(UserKey, :count) == 0
      assert TestRepo.aggregate(RecoveryCode, :count) == 0
    end

    # `1..0` counts down, so a count of zero is the one that quietly issues codes.
    test "issues none when the application asks for none" do
      {:ok, changes} =
        grant(count: 0)

      assert changes.recovery_codes == []
      assert RecoveryCodes.remaining(changes.account) == 0
    end

    test "and refuses a count that cannot mean anything" do
      for wrong <- [-1, 1.5, "twelve", nil] do
        assert_raise ArgumentError, ~r/count: must be a non-negative integer/, fn ->
          grant(count: wrong)
        end
      end
    end

    # Run against an account that somehow already holds a batch — an invitation accepted twice, a
    # second provisioning path — the older one must not stay alive beside the new one, unseen.
    test "replaces an existing batch rather than adding to it" do
      user = user_fixture()
      old_codes = RecoveryCodes.regenerate(user)

      {:ok, changes} =
        grant_for(user)

      assert RecoveryCodes.remaining(user) == 12
      assert {:error, :invalid} = RecoveryCodes.redeem(hd(old_codes))
      assert {:ok, _account, _fresh} = RecoveryCodes.redeem(hd(changes.recovery_codes))
    end

    # A credential written for somebody else is the one thing this step must not be talked into.
    test "takes the account from the multi, never from the attributes" do
      victim = user_fixture()

      attrs = Map.put(key_attrs(), :user_id, victim.id)

      {:ok, changes} =
        grant(attrs: attrs)

      assert changes.passkey.user_id == changes.account.id
      refute changes.passkey.user_id == victim.id
    end

    # A string key beside an atom one leaves the choice to `Ecto.Changeset`, which is not where this
    # library's answer to "whose credential is this" should live.
    test "and refuses attributes it did not shape, rather than resolving them by luck" do
      credential = TestCredentials.credential()
      victim = user_fixture()

      assert_raise ArgumentError, ~r/key_attrs: expected what/, fn ->
        Multi.new()
        |> Multi.insert(:account, user_changeset())
        |> Grant.with_key_and_codes(%{
          "key_id" => credential.key_id,
          "public_key" => credential.public_key,
          "user_id" => victim.id
        })
        |> TestRepo.transaction()
      end
    end

    # What an application step ending in `{:ok, repo.one(query)}` hands over when the query found
    # nothing.
    test "and says something useful when the step holds no account at all" do
      assert_raise ArgumentError, ~r/expected a Ithibati.TestUser, got nil/, fn ->
        grant_for(nil)
      end
    end

    test "and refuses an account of a schema this library was not told about" do
      assert_raise ArgumentError, ~r/expected a Ithibati.TestUser/, fn ->
        Multi.new()
        |> Multi.run(:account, fn _repo, _changes -> {:ok, %Ithibati.NamedUser{}} end)
        |> Grant.with_key_and_codes(key_attrs())
        |> TestRepo.transaction()
      end
    end
  end
end
