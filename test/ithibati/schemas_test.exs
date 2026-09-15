defmodule Ithibati.SchemasTest do
  @moduledoc """
  The tables this library owns, written and read back once each.

  It is a shallow test on purpose: what it pins is that the migration and the schemas agree — every
  column the schema names exists, with a type that round-trips. A disagreement between the two is
  otherwise found by whichever feature happens to touch the column first, at a distance from its
  cause.
  """
  use Ithibati.DataCase, async: true

  alias Ithibati.Bootstrap
  alias Ithibati.Config
  alias Ithibati.RecoveryCode
  alias Ithibati.Session
  alias Ithibati.UserKey

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

  test "a session round-trips, carrying the digest it was given", %{user: user} do
    {:ok, session} =
      %Session{}
      |> Session.changeset(%{token_hash: <<10, 11>>, user_id: user.id})
      |> TestRepo.insert()

    assert %Session{token_hash: <<10, 11>>} = TestRepo.get!(Session, session.id)
  end

  # A session is never updated — its age is its expiry — so the table has no such column and the
  # schema must not claim one.
  test "a session has no updated_at" do
    refute :updated_at in Session.__schema__(:fields)
    assert :inserted_at in Session.__schema__(:fields)
  end

  # `Bootstrap` is absent on purpose: its foreign key is nilified rather than cascaded, because a
  # deleted founder must not make a second setup possible. `Ithibati.BootstrapTest` holds that.
  test "the rows die with the account they belong to", %{user: user} do
    {:ok, _} =
      %Session{}
      |> Session.changeset(%{token_hash: <<12>>, user_id: user.id})
      |> TestRepo.insert()

    {:ok, _} =
      %UserKey{}
      |> UserKey.changeset(%{key_id: <<13>>, public_key: <<14>>, user_id: user.id})
      |> TestRepo.insert()

    {:ok, _} =
      %RecoveryCode{}
      |> RecoveryCode.changeset(%{code_hash: <<15>>, user_id: user.id})
      |> TestRepo.insert()

    assert Enum.all?([UserKey, RecoveryCode, Session], &(TestRepo.aggregate(&1, :count) == 1))

    {:ok, _} = TestRepo.delete(user)

    assert Enum.all?([UserKey, RecoveryCode, Session], &(TestRepo.aggregate(&1, :count) == 0))
  end

  # Written out rather than derived from `Config`: both sides of a derived assertion move together,
  # so it would hold for any prefix and prove only that the convention was applied to itself. These
  # are the names `docs/getting_started.md` promises and the migration builds.
  test "the tables are the ones the documentation names" do
    assert UserKey.__schema__(:source) == "ithibati_keys"
    assert RecoveryCode.__schema__(:source) == "ithibati_recovery_codes"
    assert Session.__schema__(:source) == "ithibati_sessions"
    assert Bootstrap.__schema__(:source) == "ithibati_bootstrap"
  end

  # The migration declares the same kind of foreign key for every table, reading the type off
  # `UserKey`. It may do that only while they all agree.
  test "every table takes the same kind of account key" do
    tables = [UserKey, RecoveryCode, Session, Bootstrap]
    types = Enum.map(tables, & &1.__schema__(:type, :user_id))

    assert types == List.duplicate(Config.users_key_type(), length(tables))
  end

  test "the bootstrap row round-trips", %{user: user} do
    assert {:ok, claim} = TestRepo.insert(Bootstrap.changeset(%Bootstrap{}, %{user_id: user.id}))

    read = TestRepo.get!(Bootstrap, claim.id)
    assert read.user_id == user.id
    assert read.claimed
  end
end
