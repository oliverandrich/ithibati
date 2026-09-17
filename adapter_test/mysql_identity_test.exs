if Application.get_env(:ithibati, :probe_adapter) == Ecto.Adapters.MyXQL do
  defmodule Ithibati.MySQLIdentityTest do
    use Ithibati.AdapterIdentityCase
    alias Ithibati.Doctor
    alias Ithibati.Identity.{Passkeys, RecoveryCodes}
    alias Ithibati.Schema.User, as: UserSchema

    test "recovery redemption validates isolation once before its credential writes" do
      account = user()
      [code] = RecoveryCodes.regenerate(account, count: 1)

      assert_one_isolation_check(fn ->
        assert {:ok, _, nil} = RecoveryCodes.redeem(code, refill: false)
      end)
    end

    test "passkey authentication validates isolation once" do
      account = user()
      credential = Ithibati.TestCredentials.credential()
      assert {:ok, _} = Passkeys.add_key(account, credential)

      assert {:ok, challenge} =
               Passkeys.authentication_challenge("localhost", "http://localhost:4000")

      assertion = Ithibati.TestCredentials.assertion(credential, challenge)

      assert_one_isolation_check(fn ->
        assert {:ok, authenticated} = Passkeys.verify_authentication(assertion, challenge)
        assert authenticated.id == account.id
      end)
    end

    test "doctor accepts the configured MySQL database" do
      results = Doctor.examine(:ithibati)

      for subject <- [
            "the database adapter",
            "the repo answers",
            "this library's tables",
            "config :ithibati, users_key_type:",
            "the identifier's unique index",
            "the invitation table"
          ] do
        assert {^subject, {:ok, _}} = List.keyfind!(results, subject, 0)
      end
    end

    test "doctor reports nontransactional invitation tables without crashing" do
      Repo.query!("ALTER TABLE app_invitations ENGINE=MyISAM")

      try do
        assert {_, {:error, message}} =
                 List.keyfind!(Doctor.examine(:ithibati), "the invitation table", 0)

        assert message =~ "InnoDB"
      after
        Repo.query!("ALTER TABLE app_invitations ENGINE=InnoDB")
      end
    end

    test "doctor rejects disabled foreign keys" do
      Repo.checkout(fn ->
        Repo.query!("SET SESSION foreign_key_checks = 0")

        try do
          assert {_, {:error, message}} =
                   List.keyfind!(Doctor.examine(:ithibati), "the repo answers", 0)

          assert message =~ "foreign_key_checks"
        after
          Repo.query!("SET SESSION foreign_key_checks = 1")
        end
      end)
    end

    test "unsupported transaction isolation fails before credential writes" do
      user = user()
      [code] = RecoveryCodes.regenerate(user, count: 1)

      Repo.checkout(fn ->
        Repo.query!("SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ")

        try do
          assert {_, {:error, detail}} =
                   List.keyfind!(Doctor.examine(:ithibati), "the repo answers", 0)

          assert detail =~ "READ COMMITTED"

          assert_raise ArgumentError, ~r/READ COMMITTED/, fn ->
            Repo.transaction(fn ->
              Repo.get!(User, user.id)
              RecoveryCodes.regenerate(user, count: 3)
            end)
          end
        after
          Repo.query!("SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED")
        end
      end)

      assert {:ok, _, _} = RecoveryCodes.redeem(code, refill: false)
    end

    test "an earlier application read sees a competing committed recovery replacement" do
      user = user()
      [old] = RecoveryCodes.regenerate(user, count: 1)

      assert {:ok, :checked} =
               Repo.transaction(fn ->
                 assert RecoveryCodes.remaining(user) == 1

                 fresh =
                   Task.async(fn -> RecoveryCodes.regenerate(user, count: 2) end) |> Task.await()

                 assert RecoveryCodes.remaining(user) == 2
                 assert {:ok, _, nil} = RecoveryCodes.redeem(hd(fresh))
                 :checked
               end)

      assert {:error, :invalid} = RecoveryCodes.redeem(old)
      assert RecoveryCodes.remaining(user) == 1
    end

    test "maximum length credential identifiers retain full binary uniqueness" do
      user = user()
      prefix = :binary.copy(<<0, 255>>, 511)
      attrs = %{public_key: :erlang.term_to_binary(%{1 => 2})}
      assert {:ok, first} = Passkeys.add_key(user, Map.put(attrs, :key_id, prefix <> <<0>>))
      assert {:ok, second} = Passkeys.add_key(user, Map.put(attrs, :key_id, prefix <> <<1>>))
      assert Repo.get!(Ithibati.UserKey, first.id).key_id == prefix <> <<0>>
      assert Repo.get!(Ithibati.UserKey, second.id).key_id == prefix <> <<1>>
      assert {:error, _} = Passkeys.add_key(user, Map.put(attrs, :key_id, first.key_id))
    end

    test "deadlocks escape without replaying application callbacks" do
      user = user()
      keys = [key(user), key(user)]
      parent = self()

      tasks =
        for number <- 0..1 do
          Task.async(fn ->
            try do
              Repo.transaction(fn ->
                send(parent, {:callback, number})
                assert {:ok, _} = Passkeys.rename_key(user, Enum.at(keys, number).id, "First")
                send(parent, {:locked, self()})

                receive do
                  :continue -> Passkeys.rename_key(user, Enum.at(keys, 1 - number).id, "Second")
                after
                  2_000 -> raise "deadlock barrier timed out"
                end
              end)
            rescue
              error in MyXQL.Error -> {:database_error, error.mysql.code}
            end
          end)
        end

      try do
        assert_receive {:callback, 0}, 2_000
        assert_receive {:callback, 1}, 2_000
        assert_receive {:locked, first}, 2_000
        assert_receive {:locked, second}, 2_000
        send(first, :continue)
        send(second, :continue)
        results = Enum.map(tasks, &Task.await(&1, 5_000))
        assert {:database_error, 1213} in results
        assert Enum.count(results, &match?({:ok, {:ok, _}}, &1)) == 1
        refute_received {:callback, _}
      after
        Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
      end
    end

    test "lock timeout escapes and the enclosing transaction remains the caller's choice" do
      user = user()
      key = key(user)

      assert {:ok, :held} =
               Repo.transaction(fn ->
                 assert {:ok, _} = Passkeys.rename_key(user, key.id, "Held")

                 task =
                   Task.async(fn ->
                     Repo.checkout(fn ->
                       [[timeout]] = Repo.query!("SELECT @@innodb_lock_wait_timeout").rows
                       Repo.query!("SET SESSION innodb_lock_wait_timeout = 1")

                       try do
                         error =
                           assert_raise MyXQL.Error, fn ->
                             Passkeys.rename_key(user, key.id, "Blocked")
                           end

                         assert error.mysql.code == 1205
                       after
                         Repo.query!("SET SESSION innodb_lock_wait_timeout = #{timeout}")
                       end
                     end)
                   end)

                 Task.await(task, 4_000)
                 :held
               end)

      assert Repo.get!(Ithibati.UserKey, key.id).label == "Held"
    end

    test "normalized identifiers and the unique index agree" do
      changeset = User.identifier_changeset(%User{}, %{email: "  Ada@Example.test  "})
      assert {:ok, user} = Repo.insert(changeset)
      assert user.email == "ada@example.test"

      assert {:error, duplicate} =
               Repo.insert(User.identifier_changeset(%User{}, %{email: "ADA@example.test"}))

      assert UserSchema.identifier_taken?(duplicate)
      assert Repo.get_by!(User, email: "ada@example.test").id == user.id
    end

    defp assert_one_isolation_check(fun) do
      parent = self()
      ref = make_ref()
      event = Repo.config()[:telemetry_prefix] ++ [:query]

      :telemetry.attach(
        ref,
        event,
        fn _, _, metadata, _ ->
          if self() == parent and metadata.query == "SELECT @@transaction_isolation" do
            send(parent, {ref, :isolation})
          end
        end,
        nil
      )

      try do
        fun.()
        assert_received {^ref, :isolation}
        refute_received {^ref, :isolation}
      after
        :telemetry.detach(ref)
      end
    end
  end
end
