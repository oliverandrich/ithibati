if Application.get_env(:ithibati, :probe_adapter) in [Ecto.Adapters.SQLite3, Ecto.Adapters.MyXQL] do
  defmodule Ithibati.AdapterAuthenticationTest do
    use Ithibati.AdapterIdentityCase
    alias Ithibati.Identity.Passkeys
    alias Ithibati.TestCredentials

    setup do
      user = user()
      credential = TestCredentials.credential()
      {:ok, key} = Passkeys.add_key(user, credential)
      {:ok, challenge} = Passkeys.authentication_challenge("localhost", "http://localhost")

      %{
        user: user,
        key: key,
        assertion: TestCredentials.assertion(credential, challenge),
        challenge: challenge
      }
    end

    test "a verified signature returns the account, not credential columns", ctx do
      assert {:ok, account} = Passkeys.verify_authentication(ctx.assertion, ctx.challenge)
      assert account.id == ctx.user.id
      assert account.email == ctx.user.email
      assert Repo.get!(Ithibati.UserKey, ctx.key.id).last_used_at
    end

    test "deletion after lookup is refused at the conditional write", ctx do
      parent = self()
      handler = {__MODULE__, make_ref()}
      event = Repo.config()[:telemetry_prefix] ++ [:query]
      :ok = :telemetry.attach(handler, event, &__MODULE__.pause_lookup/4, parent)
      on_exit(fn -> :telemetry.detach(handler) end)
      task = Task.async(fn -> Passkeys.verify_authentication(ctx.assertion, ctx.challenge) end)

      try do
        assert_receive {:lookup, auth}, 2_000
        Repo.delete!(ctx.key)
        send(auth, :continue)
        assert {:error, :unknown_credential} = Task.await(task, 3_000)
      after
        :telemetry.detach(handler)
        Task.shutdown(task, :brutal_kill)
      end
    end

    test "a refused authentication does not roll back the caller's other changes", ctx do
      handler = {__MODULE__, make_ref()}
      event = Repo.config()[:telemetry_prefix] ++ [:query]
      :ok = :telemetry.attach(handler, event, &__MODULE__.delete_after_lookup/4, ctx.key)

      try do
        assert {:ok, :kept} =
                 Repo.transaction(fn ->
                   assert {:error, :unknown_credential} =
                            Passkeys.verify_authentication(ctx.assertion, ctx.challenge)

                   :kept
                 end)

        refute Repo.get(Ithibati.UserKey, ctx.key.id)
      after
        :telemetry.detach(handler)
      end
    end

    def delete_after_lookup(_event, _measurements, metadata, key) do
      if credential_lookup?(metadata.query), do: Repo.delete!(key)
    end

    def pause_lookup(_event, _measurements, metadata, parent) do
      if credential_lookup?(metadata.query) do
        send(parent, {:lookup, self()})

        receive do
          :continue -> :ok
        after
          2_000 -> raise "authentication lookup barrier timed out"
        end
      end
    end

    defp credential_lookup?(query) do
      String.starts_with?(query, "SELECT") and
        String.contains?(query, "ithibati_keys") and
        Regex.match?(~r/WHERE.*["`]key_id["`]/, query)
    end
  end
end
