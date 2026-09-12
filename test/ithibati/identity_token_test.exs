defmodule Ithibati.IdentityTokenTest do
  @moduledoc """
  Revocable tokens: what is handed out, what is written down, and what a context is worth.

  The contexts other than `"session"` come from `config/config.exs`, so nothing here moves
  application environment and the module can stay async.
  """
  use Ithibati.DataCase, async: true

  alias Ithibati.Identity
  alias Ithibati.UserToken

  setup do
    %{user: user_fixture()}
  end

  describe "generate_token/2" do
    test "hands out a secret and writes down only its digest", %{user: user} do
      token = Identity.generate_token(user, "session")

      row = TestRepo.one!(from t in UserToken, where: t.user_id == ^user.id)

      # First assertion, because it is the whole claim: the secret is not in the database.
      refute row.token_hash == token
      assert row.token_hash == :crypto.hash(:sha256, token)
      assert row.context == "session"

      # URL-safe text rather than the raw bytes, so it survives an `authorization` header and a
      # query string without the caller encoding anything.
      assert token =~ ~r/\A[A-Za-z0-9_-]{43}\z/
    end

    test "two calls mint two different secrets", %{user: user} do
      refute Identity.generate_token(user, "session") ==
               Identity.generate_token(user, "session")
    end

    test "a context nobody configured is refused where it is written", %{user: user} do
      assert_raise ArgumentError, ~r/no validity is configured for that context/, fn ->
        Identity.generate_token(user, "sesion")
      end
    end

    # With `users_key_type: :id` a struct from elsewhere whose `id` happens to be 1 would otherwise
    # mint a working token for account 1.
    test "a struct that is not the configured account schema is refused", %{user: user} do
      assert_raise ArgumentError, ~r/expected a Ithibati.TestUser/, fn ->
        Identity.generate_token(%UserToken{id: user.id}, "session")
      end
    end
  end

  describe "get_user_by_token/2" do
    test "answers the account behind a fresh token", %{user: user} do
      token = Identity.generate_token(user, "session")

      assert %{id: id} = Identity.get_user_by_token(token, "session")
      assert id == user.id
    end

    test "a token minted in one context is not accepted in another", %{user: user} do
      token = Identity.generate_token(user, "session")

      refute Identity.get_user_by_token(token, "device")
      assert Identity.get_user_by_token(token, "session")
    end

    test "a token older than its context's validity is not accepted", %{user: user} do
      token = Identity.generate_token(user, "session")
      backdate(token, days(61))

      refute Identity.get_user_by_token(token, "session")
    end

    # The same age, two contexts, two answers — which is the property a single module attribute
    # could not have had.
    test "each context expires on its own clock", %{user: user} do
      old_session = Identity.generate_token(user, "session")
      old_device = Identity.generate_token(user, "device")

      backdate(old_session, days(70))
      backdate(old_device, days(70))

      refute Identity.get_user_by_token(old_session, "session")
      assert Identity.get_user_by_token(old_device, "device")
    end

    # The arithmetic is `DateTime.shift/2`'s, so what is worth pinning is not the number of seconds
    # in a minute but that the unit reaches it at all: read as days, this token lives five days.
    test "the unit is honoured, not only the number", %{user: user} do
      token = Identity.generate_token(user, "brief")
      backdate(token, 10)

      refute Identity.get_user_by_token(token, "brief")
    end

    test "a token nobody minted is nobody's" do
      refute Identity.get_user_by_token(stranger(), "session")
    end

    # What a missing session key and a missing `authorization` header both hand you.
    test "nil is answered, not raised on" do
      refute Identity.get_user_by_token(nil, "session")
    end

    # Before the token is looked at, which is why `nil` does not get an answer here.
    test "a context nobody configured is refused first" do
      assert_raise ArgumentError, ~r/no validity is configured for that context/, fn ->
        Identity.get_user_by_token(nil, "sesion")
      end
    end
  end

  describe "delete_token/2" do
    test "revokes", %{user: user} do
      token = Identity.generate_token(user, "session")

      assert :ok == Identity.delete_token(token, "session")
      refute Identity.get_user_by_token(token, "session")
    end

    test "is scoped to its context, like the lookup", %{user: user} do
      token = Identity.generate_token(user, "session")

      assert :ok == Identity.delete_token(token, "device")
      assert Identity.get_user_by_token(token, "session")
    end

    test "revoking one that does not exist is not an error" do
      assert :ok == Identity.delete_token(stranger(), "session")
    end

    test "nil is not an error either" do
      assert :ok == Identity.delete_token(nil, "session")
    end

    # The one function that does not check the context against the configuration, because retiring
    # a context is exactly when its outstanding tokens have to be revocable.
    test "a context that is no longer configured can still be revoked", %{user: user} do
      token = stranger()

      TestRepo.insert!(
        UserToken.changeset(%UserToken{}, %{
          token_hash: digest(token),
          context: "retired",
          user_id: user.id
        })
      )

      assert :ok == Identity.delete_token(token, "retired")
      assert TestRepo.aggregate(from(t in UserToken, where: t.context == "retired"), :count) == 0
    end
  end

  describe "the session conveniences" do
    test "are the general functions with one word filled in", %{user: user} do
      token = Identity.generate_session_token(user)

      assert %{id: id} = Identity.get_user_by_session_token(token)
      assert id == user.id

      # The same token, reached through the general function under the context the convenience
      # promises — which is what makes them one implementation rather than two.
      assert Identity.get_user_by_token(token, "session")

      assert :ok == Identity.delete_session_token(token)
      refute Identity.get_user_by_session_token(token)
    end
  end

  defp days(n), do: n * 86_400

  # Shaped like a token this library would mint, belonging to nothing.
  defp stranger, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp digest(token), do: :crypto.hash(:sha256, token)

  # Backdating the row rather than sleeping: the expiry is a comparison against `inserted_at`, and
  # a test that waits for it is either slow or lying about how long it waited.
  defp backdate(token, seconds) do
    then = DateTime.add(DateTime.utc_now(), -seconds, :second)

    {1, _} =
      TestRepo.update_all(
        from(t in UserToken, where: t.token_hash == ^digest(token)),
        set: [inserted_at: then]
      )

    :ok
  end
end
