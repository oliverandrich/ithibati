defmodule Ithibati.Identity.SessionsRaceTest do
  use Ithibati.RaceCase

  alias Ithibati.Identity.Secrets
  alias Ithibati.Identity.Sessions

  test "concurrent revocations return each deleted digest exactly once" do
    account = Ithibati.DataCase.user_fixture()
    tokens = for _ <- 1..8, do: Sessions.generate_session_token(account)

    results = racing_connections(4, fn -> Sessions.revoke_all(account) end)

    assert Enum.sort(List.flatten(results)) == Enum.sort(Enum.map(tokens, &Secrets.digest/1))
    assert TestRepo.aggregate(Ithibati.Session, :count) == 0
  end

  defp clear, do: TestRepo.delete_all(Ithibati.TestUser)
end
