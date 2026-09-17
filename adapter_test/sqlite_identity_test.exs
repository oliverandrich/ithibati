if Application.get_env(:ithibati, :probe_adapter) == Ecto.Adapters.SQLite3 do
  defmodule Ithibati.SQLiteIdentityTest do
    use Ithibati.SQLiteCase
    alias Ecto.Multi

    alias Ithibati.Identity.{
      Concurrency,
      Grant,
      Instance,
      Invitations,
      Passkeys,
      RecoveryCodes,
      Secrets,
      Sessions
    }

    test "recovery codes are single-use and final redemption refills exactly once" do
      user = user()
      [code] = RecoveryCodes.regenerate(user, count: 1)
      results = race(fn _ -> RecoveryCodes.redeem(code, count: 2) end)
      assert Enum.count(results, &match?({:ok, _, [_, _]}, &1)) == 1
      assert {:error, :invalid} in results
      assert RecoveryCodes.remaining(user) == 2
    end

    test "concurrent final-key deletion keeps one credential" do
      user = user()
      keys = [key(user), key(user)]
      results = race(fn i -> Passkeys.delete_key(user, Enum.at(keys, i - 1).id) end)
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert {:error, :last_key} in results
      assert [_] = Passkeys.list_keys(user)
    end

    test "an application-owned transaction may read before changing recovery codes" do
      user = user()

      assert {:ok, [_]} =
               Repo.transaction(fn ->
                 assert Repo.get!(User, user.id).id == user.id
                 RecoveryCodes.regenerate(user, count: 1)
               end)
    end

    test "invitation acceptance and bootstrap each have exactly one winner" do
      invitation =
        Repo.insert!(
          Invitation.invitation_changeset(%Invitation{}, %{email: "invited@example.test"})
        )

      results =
        race(fn _ -> Multi.new() |> Invitations.accept(invitation) |> Repo.transaction() end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.any?(results, &match?({:error, :invitation, :invalid_invitation, _}, &1))
      user = user()

      results =
        race(fn _ ->
          Multi.new() |> Multi.put(:account, user) |> Instance.claim() |> Repo.transaction()
        end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.any?(results, &match?({:error, :bootstrap, :already_claimed, _}, &1))
      Repo.delete!(user)
      refute Instance.needs_setup?()
    end

    test "different final recovery codes refill only once" do
      user = user()
      codes = RecoveryCodes.regenerate(user, count: 2)
      results = race(fn i -> RecoveryCodes.redeem(Enum.at(codes, i - 1), count: 3) end)
      assert Enum.count(results, &match?({:ok, _, nil}, &1)) == 1
      assert Enum.count(results, &match?({:ok, _, [_, _, _]}, &1)) == 1
      assert RecoveryCodes.remaining(user) == 3
    end

    test "concurrent regenerations leave one complete batch" do
      user = user()
      batches = race(fn _ -> RecoveryCodes.regenerate(user, count: 3) end)
      hashes = Repo.all(Ithibati.RecoveryCode) |> Enum.map(& &1.code_hash) |> Enum.sort()

      assert Enum.any?(batches, fn codes ->
               codes |> Enum.map(&Secrets.digest/1) |> Enum.sort() == hashes
             end)

      assert RecoveryCodes.remaining(user) == 3
    end

    test "regeneration and redemption preserve the replacing batch" do
      user = user()
      [old] = RecoveryCodes.regenerate(user, count: 1)

      [fresh, redeemed] =
        race(fn
          1 -> RecoveryCodes.regenerate(user, count: 3)
          2 -> RecoveryCodes.redeem(old, count: 2)
        end)

      assert match?({:ok, _, _}, redeemed) or redeemed == {:error, :invalid}
      assert RecoveryCodes.remaining(user) == 3
      hashes = Repo.all(Ithibati.RecoveryCode) |> Enum.map(& &1.code_hash) |> Enum.sort()
      assert fresh |> Enum.map(&Secrets.digest/1) |> Enum.sort() == hashes
    end

    test "a stale application snapshot raises before replacing recovery codes" do
      user = user()
      RecoveryCodes.regenerate(user, count: 2)

      assert_raise Exqlite.Error, ~r/[Bb]usy|locked/, fn ->
        Repo.transaction(fn ->
          Repo.get!(User, user.id)

          task =
            Task.async(fn ->
              user |> Ecto.Changeset.change(email: "changed@example.test") |> Repo.update!()
            end)

          Task.await(task)
          RecoveryCodes.regenerate(user, count: 3)
        end)
      end

      assert RecoveryCodes.remaining(user) == 2
    end

    @tag capture_log: true
    test "the library writer reservation lasts until the outer transaction commits" do
      user = user()

      assert {:ok, :held} =
               Repo.transaction(fn ->
                 RecoveryCodes.regenerate(user, count: 2)

                 task =
                   Task.async(fn ->
                     assert_raise Exqlite.Error, ~r/[Bb]usy|locked/, fn ->
                       RecoveryCodes.regenerate(user, count: 3)
                     end
                   end)

                 assert %Exqlite.Error{} = Task.await(task, 3_000)
                 :held
               end)

      assert RecoveryCodes.remaining(user) == 2
    end

    test "renaming preserves ownership and account deletion cascades credentials" do
      user = user()
      key = key(user)
      stranger = user()
      assert {:error, :not_found} = Passkeys.rename_key(stranger, key.id, "Other")
      assert {:ok, renamed} = Passkeys.rename_key(user, key.id, "Laptop")
      assert renamed.label == "Laptop"
      assert {:ok, _} = Passkeys.rename_key(user, key.id, "Laptop")
      RecoveryCodes.regenerate(user)
      Repo.delete!(user)
      refute Repo.get(Ithibati.UserKey, key.id)
      assert Repo.all(Ithibati.RecoveryCode) == []
    end

    @tag capture_log: true
    test "the account lock reserves the writer before credential decisions" do
      user = user()

      assert {:ok, :locked} =
               Repo.transaction(fn ->
                 Repo.get!(User, user.id)
                 Concurrency.lock_account!(user.id)

                 task =
                   Task.async(fn ->
                     assert_raise Exqlite.Error, ~r/busy|locked/i, fn ->
                       user
                       |> Ecto.Changeset.change(email: "blocked@example.test")
                       |> Repo.update!()
                     end
                   end)

                 assert %Exqlite.Error{} = Task.await(task, 3_000)
                 :locked
               end)

      assert Repo.get!(User, user.id).email == user.email
    end

    test "sessions resolve, expire and revoke against SQLite timestamps" do
      user = user()
      token = Sessions.generate_session_token(user)
      assert Sessions.get_user_by_session_token(token).id == user.id
      Sessions.delete_session_token(token)
      refute Sessions.get_user_by_session_token(token)

      expired = Sessions.generate_session_token(user)
      [session] = Repo.all(Ithibati.Session)

      session
      |> Ecto.Changeset.change(inserted_at: ~U[2000-01-01 00:00:00.123456Z])
      |> Repo.update!()

      refute Sessions.get_user_by_session_token(expired)
      Repo.delete!(user)
      assert Repo.all(Ithibati.Session) == []
    end

    test "failed grants roll back the account" do
      user = user()
      existing = key(user)

      result =
        Multi.new()
        |> Multi.insert(
          :account,
          User.identifier_changeset(%User{}, %{email: "failed@example.test"})
        )
        |> Grant.with_key_and_codes(%{key_id: existing.key_id, public_key: existing.public_key})
        |> Repo.transaction()

      assert {:error, :passkey, _, _} = result
      refute Repo.get_by(User, email: "failed@example.test")
    end
  end
end
