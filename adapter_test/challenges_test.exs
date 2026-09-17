if Application.compile_env!(:ithibati, :probe_adapter) in [
     Ecto.Adapters.SQLite3,
     Ecto.Adapters.MyXQL
   ] do
  defmodule Ithibati.AdapterChallengesTest do
    use Ithibati.AdapterIdentityCase
    alias Ithibati.Identity.Challenges
    alias Ithibati.Identity.Passkeys

    test "expiry and transaction boundaries cannot authorize a challenge" do
      challenge = Passkeys.registration_challenge("example.test", "https://example.test")
      Challenges.store(challenge)

      Repo.transaction(fn ->
        assert_raise ArgumentError, ~r/outside.*transaction/, fn ->
          Challenges.consume(challenge)
        end
      end)

      Repo.update_all(Ithibati.Challenge,
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert Challenges.consume(challenge) == {:error, :no_challenge}
      assert Challenges.delete_expired() == 1
      assert Challenges.delete_expired() == 0
    end

    test "version 2 rolls back and upgrades without losing account data" do
      account = user()
      assert :ok = Ecto.Migrator.down(Repo, 14, Ithibati.AdapterChallengeMigration, log: false)
      assert Ithibati.Catalogue.table(Repo, nil, "ithibati_challenges") == nil
      assert Repo.get!(User, account.id).id == account.id
      assert :ok = Ecto.Migrator.up(Repo, 14, Ithibati.AdapterChallengeMigration, log: false)
      assert Repo.get!(User, account.id).id == account.id
      challenge = Passkeys.registration_challenge("example.test", "https://example.test")
      assert Challenges.store(challenge) == :ok
      assert Challenges.consume(challenge) == :ok
    end

    test "challenge consumption is atomic across independent connections" do
      challenge = Passkeys.registration_challenge("example.test", "https://example.test")
      assert Challenges.store(challenge) == :ok
      results = race(fn _ -> Challenges.consume(challenge) end)
      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :no_challenge})) == 1
    end
  end
end
