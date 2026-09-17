defmodule Ithibati.Identity.ChallengesTest do
  use Ithibati.DataCase, async: true
  alias Ithibati.Challenge
  alias Ithibati.Identity.Challenges
  alias Ithibati.Identity.Passkeys
  alias Ithibati.Identity.Secrets

  test "only issued, unexpired challenges can be consumed once" do
    challenge = Passkeys.registration_challenge("example.test", "https://example.test")
    assert Challenges.consume(challenge) == {:error, :no_challenge}
    assert Challenges.store(challenge) == :ok
    assert Challenges.consume(challenge) == :ok
    assert Challenges.consume(challenge) == {:error, :no_challenge}
  end

  test "expiry refuses verification and cleanup preserves live challenges" do
    expired = Passkeys.registration_challenge("example.test", "https://example.test")
    live = Passkeys.registration_challenge("example.test", "https://example.test")
    Challenges.store(expired)
    Challenges.store(live)

    TestRepo.update_all(
      from(c in Challenge, where: c.token_hash == ^Secrets.digest(expired.bytes)),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert Challenges.consume(expired) == {:error, :no_challenge}
    assert Challenges.delete_expired() == 1
    assert Challenges.delete_expired() == 0
    assert Challenges.consume(live) == :ok
  end

  test "an outer transaction cannot roll back successful consumption" do
    challenge = Passkeys.registration_challenge("example.test", "https://example.test")
    Challenges.store(challenge)

    TestRepo.transaction(fn ->
      assert_raise ArgumentError, ~r/outside.*transaction/, fn ->
        Challenges.consume(challenge)
      end
    end)

    assert Challenges.consume(challenge) == :ok
  end
end
