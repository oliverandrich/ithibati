if Application.compile_env!(:ithibati, :probe_adapter) in [
     Ecto.Adapters.SQLite3,
     Ecto.Adapters.MyXQL
   ] do
  defmodule Ithibati.AdapterConcurrencyTest do
    use Ithibati.AdapterIdentityCase
    import Ecto.Query
    alias Ithibati.Identity.Concurrency

    if Application.compile_env!(:ithibati, :probe_adapter) == Ecto.Adapters.SQLite3 do
      test "a stale outer snapshot is refused before the identity callback starts" do
        account = user()
        ref = make_ref()

        Repo.transaction(fn ->
          Repo.get!(User, account.id)

          Task.async(fn ->
            account |> Ecto.Changeset.change(email: "fresh@example.test") |> Repo.update!()
          end)
          |> Task.await()

          assert_raise Exqlite.Error, ~r/[Bb]usy|locked/, fn ->
            Concurrency.transaction(Repo, fn -> send(self(), {ref, :callback}) end)
          end

          refute_received {^ref, :callback}
        end)
      end
    end

    test "building a locking query outside a transaction does not access the database" do
      parent = self()
      ref = make_ref()
      event = Repo.config()[:telemetry_prefix] ++ [:query]

      :telemetry.attach(
        ref,
        event,
        fn _, _, _, _ ->
          if self() == parent, do: send(parent, {ref, :query})
        end,
        nil
      )

      try do
        assert %Ecto.Query{} = Concurrency.lock_rows(from(u in User))
        refute_received {^ref, :query}
      after
        :telemetry.detach(ref)
      end
    end
  end
end
