defmodule Ithibati.Identity.ChallengesRaceTest do
  use Ithibati.RaceCase
  alias Ithibati.Challenge
  alias Ithibati.Identity.Challenges
  alias Ithibati.Identity.Passkeys

  test "independent connections consume one challenge at most once" do
    challenge = Passkeys.registration_challenge("example.test", "https://example.test")
    Challenges.store(challenge)
    results = racing_connections(4, fn -> Challenges.consume(challenge) end)
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :no_challenge})) == 3
  end

  defp clear do
    TestRepo.delete_all(Challenge)
    TestRepo.delete_all(Ithibati.TestUser)
  end
end
