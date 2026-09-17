defmodule Ithibati.Identity.MutationsTest do
  use Ithibati.DataCase, async: true
  alias Ithibati.Identity.Mutations

  test "the prepared update refuses to execute outside a transaction" do
    account = user_fixture()
    key = key_fixture(account)
    query = from(k in Ithibati.UserKey, where: k.id == ^key.id, select: k)

    assert_raise ArgumentError, ~r/prepared identity transaction/, fn ->
      Mutations.update_one_in_transaction(TestRepo, query, [set: [label: "Changed"]], :not_found)
    end

    assert TestRepo.get!(Ithibati.UserKey, key.id).label == key.label
  end
end
