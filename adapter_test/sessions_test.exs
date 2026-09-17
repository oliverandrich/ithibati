if Application.compile_env!(:ithibati, :probe_adapter) in [
     Ecto.Adapters.SQLite3,
     Ecto.Adapters.MyXQL
   ] do
  defmodule Ithibati.AdapterSessionsTest do
    use Ithibati.AdapterIdentityCase
    import Ecto.Query
    alias Ithibati.Identity.Secrets
    alias Ithibati.Identity.Sessions
    alias Ithibati.Session

    test "bulk revocation isolates accounts and returns each deleted digest once under contention" do
      account = user()
      tokens = for _ <- 1..8, do: Sessions.generate_session_token(account)
      other = Sessions.generate_session_token(user())

      results = race(fn _ -> Sessions.revoke_all(account) end)

      assert Enum.sort(List.flatten(results)) == Enum.sort(Enum.map(tokens, &Secrets.digest/1))
      assert Repo.aggregate(from(s in Session, where: s.user_id == ^account.id), :count) == 0
      assert Sessions.get_user_by_session_token(other)
      assert Sessions.revoke_all(account) == []
    end

    test "cleanup deletes only expired sessions and returns their count" do
      account = user()
      expired = Sessions.generate_session_token(account)
      valid = Sessions.generate_session_token(account)
      cutoff = DateTime.shift(DateTime.utc_now(), day: -61)

      Repo.update_all(from(s in Session, where: s.token_hash == ^Secrets.digest(expired)),
        set: [inserted_at: cutoff]
      )

      assert Sessions.delete_expired() == 1
      assert [row] = Repo.all(Session)
      assert row.token_hash == Secrets.digest(valid)
      assert Sessions.get_user_by_session_token(valid)
      assert Sessions.delete_expired() == 0
    end

    test "bulk revocation rolls back with a caller transaction" do
      account = user()
      token = Sessions.generate_session_token(account)
      digest = Secrets.digest(token)

      assert {:error, :cancelled} =
               Repo.transaction(fn ->
                 assert Sessions.revoke_all(account) == [digest]
                 refute Sessions.get_user_by_session_token(token)
                 Repo.rollback(:cancelled)
               end)

      assert Sessions.get_user_by_session_token(token)
    end
  end
end
