defmodule Ithibati.Identity.PasskeysUnwrappedTest do
  @moduledoc """
  `add_key/2` called the way the documentation shows it: on its own, with no transaction around
  it.

  Every other test of this function runs inside `Ecto.Adapters.SQL.Sandbox`, which wraps each
  test in a transaction — so `mode: :savepoint` always found the enclosing transaction it needs
  and the standalone call was never exercised. A consumer's first call has no such transaction.
  The suite could not see that, which is why this module is here rather than beside the others.

  Not async and not sandboxed, which `Ithibati.RaceCase` explains.
  """
  use Ithibati.RaceCase

  import Ithibati.DataCase, only: [user_fixture: 1]

  alias Ithibati.Identity.Passkeys
  alias Ithibati.TestCredentials
  alias Ithibati.TestUser
  alias Ithibati.UserKey

  test "enrols a credential with no transaction of the caller's own" do
    user = user_fixture(%{email: "unwrapped@example.test"})
    credential = TestCredentials.credential()

    assert {:ok, key} = Passkeys.add_key(user, attrs(credential, "First device"))
    assert key.label == "First device"
  end

  test "and still refuses a duplicate there, rather than raising" do
    user = user_fixture(%{email: "unwrapped-twice@example.test"})
    credential = TestCredentials.credential()

    {:ok, _key} = Passkeys.add_key(user, attrs(credential, "First device"))

    assert {:error, :already_enrolled} = Passkeys.add_key(user, attrs(credential, "Again"))
  end

  defp attrs(credential, label) do
    Passkeys.key_attrs(%{key_id: credential.key_id, public_key: credential.public_key}, label)
  end

  # Committed rather than rolled back, because the sandbox is off here.
  defp clear do
    TestRepo.delete_all(UserKey)
    TestRepo.delete_all(TestUser)
  end
end
