defmodule Ithibati.SchemasTest do
  @moduledoc """
  The three tables this library owns, written and read back once each.

  It is a shallow test on purpose: what it pins is that the migration and the schemas agree — every
  column the schema names exists, with a type that round-trips. A disagreement between the two is
  otherwise found by whichever feature happens to touch the column first, at a distance from its
  cause.
  """
  use Ithibati.DataCase, async: true

  alias Ithibati.Config
  alias Ithibati.RecoveryCode
  alias Ithibati.UserKey
  alias Ithibati.UserToken

  setup do
    %{user: user_fixture(%{email: "holder@example.test"})}
  end

  test "a passkey round-trips", %{user: user} do
    {:ok, key} =
      %UserKey{}
      |> UserKey.changeset(%{
        key_id: <<1, 2, 3>>,
        public_key: <<4, 5, 6>>,
        label: "1Password",
        last_used_at: DateTime.utc_now(),
        user_id: user.id
      })
      |> TestRepo.insert()

    assert %UserKey{key_id: <<1, 2, 3>>, public_key: <<4, 5, 6>>, label: "1Password"} =
             read = TestRepo.get!(UserKey, key.id)

    assert read.user_id == user.id
    assert read.last_used_at == key.last_used_at
  end

  test "a recovery code round-trips, and is spent rather than deleted", %{user: user} do
    {:ok, code} =
      %RecoveryCode{}
      |> RecoveryCode.changeset(%{code_hash: <<7, 8, 9>>, user_id: user.id})
      |> TestRepo.insert()

    assert %RecoveryCode{used_at: nil} = TestRepo.get!(RecoveryCode, code.id)

    spent_at = DateTime.utc_now()
    {:ok, _} = code |> RecoveryCode.changeset(%{used_at: spent_at}) |> TestRepo.update()

    assert %RecoveryCode{used_at: ^spent_at} = TestRepo.get!(RecoveryCode, code.id)
  end

  # Every write path goes through the changeset, which is why the fallback lives there: a person who
  # leaves the nickname box alone sends a blank string, not an absent one.
  test "a passkey with no name gets one", %{user: user} do
    for label <- [nil, "", "   "] do
      {:ok, key} =
        %UserKey{}
        |> UserKey.changeset(%{
          key_id: :crypto.strong_rand_bytes(16),
          public_key: <<1>>,
          label: label,
          user_id: user.id
        })
        |> TestRepo.insert()

      assert key.label == "Passkey"
    end
  end

  test "and one that has a name keeps it", %{user: user} do
    {:ok, key} =
      %UserKey{}
      |> UserKey.changeset(%{
        key_id: :crypto.strong_rand_bytes(16),
        public_key: <<1>>,
        label: "  Oliver's phone  ",
        user_id: user.id
      })
      |> TestRepo.insert()

    assert key.label == "Oliver's phone"
  end

  test "a token round-trips and carries its context", %{user: user} do
    {:ok, token} =
      %UserToken{}
      |> UserToken.changeset(%{token_hash: <<10, 11>>, context: "session", user_id: user.id})
      |> TestRepo.insert()

    assert %UserToken{context: "session"} = TestRepo.get!(UserToken, token.id)
  end

  # A token is never updated — its age is its expiry — so the table has no such column and the
  # schema must not claim one.
  test "a token has no updated_at" do
    refute :updated_at in UserToken.__schema__(:fields)
    assert :inserted_at in UserToken.__schema__(:fields)
  end

  test "the rows die with the account they belong to", %{user: user} do
    {:ok, _} =
      %UserToken{}
      |> UserToken.changeset(%{token_hash: <<12>>, context: "s", user_id: user.id})
      |> TestRepo.insert()

    {:ok, _} =
      %UserKey{}
      |> UserKey.changeset(%{key_id: <<13>>, public_key: <<14>>, user_id: user.id})
      |> TestRepo.insert()

    {:ok, _} =
      %RecoveryCode{}
      |> RecoveryCode.changeset(%{code_hash: <<15>>, user_id: user.id})
      |> TestRepo.insert()

    assert Enum.all?([UserKey, RecoveryCode, UserToken], &(TestRepo.aggregate(&1, :count) == 1))

    {:ok, _} = TestRepo.delete(user)

    assert Enum.all?([UserKey, RecoveryCode, UserToken], &(TestRepo.aggregate(&1, :count) == 0))
  end

  # Written out rather than derived from `Config`: both sides of a derived assertion move together,
  # so it would hold for any prefix and prove only that the convention was applied to itself. These
  # are the names the README promises and the migration builds.
  test "the tables are the ones the README names" do
    assert UserKey.__schema__(:source) == "ithibati_keys"
    assert RecoveryCode.__schema__(:source) == "ithibati_recovery_codes"
    assert UserToken.__schema__(:source) == "ithibati_tokens"
  end

  # The migration declares one foreign key for all three tables, reading the type off `UserKey`. It
  # may do that only while the three agree.
  test "every table takes the same kind of account key" do
    types = Enum.map([UserKey, RecoveryCode, UserToken], & &1.__schema__(:type, :user_id))

    assert types == [Config.users_key_type(), Config.users_key_type(), Config.users_key_type()]
  end
end
