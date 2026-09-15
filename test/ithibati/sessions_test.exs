defmodule Ithibati.Identity.SessionsTest do
  @moduledoc """
  Session tokens: what is handed out, what is written down, and what the lookup refuses.

  Nothing here moves application environment, so the module stays async. The validity is the one
  thing that has to be moved to be tested, and that lives in
  `Ithibati.Identity.SessionsValidityTest`.
  """
  use Ithibati.DataCase, async: true

  alias Ithibati.Identity.Secrets
  alias Ithibati.Identity.Sessions
  alias Ithibati.Session

  setup do
    %{user: user_fixture()}
  end

  describe "generate_session_token/1" do
    test "hands out a secret and writes down only its digest", %{user: user} do
      token = Sessions.generate_session_token(user)

      row = TestRepo.one!(from s in Session, where: s.user_id == ^user.id)

      # First assertion, because it is the whole claim: the secret is not in the database.
      refute row.token_hash == token
      assert row.token_hash == :crypto.hash(:sha256, token)

      # URL-safe text rather than the raw bytes, so it survives an `authorization` header and a
      # query string without the caller encoding anything.
      assert token =~ ~r/\A[A-Za-z0-9_-]{43}\z/
    end

    test "two calls mint two different secrets", %{user: user} do
      refute Sessions.generate_session_token(user) == Sessions.generate_session_token(user)
    end

    # With `users_key_type: :id` a struct from elsewhere whose `id` happens to be 1 would otherwise
    # mint a working session for account 1.
    test "a struct that is not the configured account schema is refused", %{user: user} do
      assert_raise ArgumentError, ~r/expected a Ithibati.TestUser/, fn ->
        Sessions.generate_session_token(%Session{id: user.id})
      end
    end
  end

  describe "get_user_by_session_token/1" do
    test "answers the account behind a fresh token", %{user: user} do
      token = Sessions.generate_session_token(user)

      assert %{id: id} = Sessions.get_user_by_session_token(token)
      assert id == user.id
    end

    test "a session older than the configured validity is not accepted", %{user: user} do
      token = Sessions.generate_session_token(user)

      refute token |> backdated(days(61)) |> Sessions.get_user_by_session_token()
    end

    test "a token nobody minted is nobody's" do
      refute Sessions.get_user_by_session_token(stranger())
    end

    # What a missing session key hands you.
    test "nil is answered, not raised on" do
      refute Sessions.get_user_by_session_token(nil)
    end
  end

  describe "delete_session_token/1" do
    test "revokes", %{user: user} do
      token = Sessions.generate_session_token(user)

      assert :ok == Sessions.delete_session_token(token)
      refute Sessions.get_user_by_session_token(token)
    end

    test "revoking one that does not exist is not an error" do
      assert :ok == Sessions.delete_session_token(stranger())
    end

    test "nil is not an error either" do
      assert :ok == Sessions.delete_session_token(nil)
    end

    # One row, not the account's others: a person signing out of one browser stays signed in on
    # their phone.
    test "revokes the one token it is handed and no other", %{user: user} do
      one = Sessions.generate_session_token(user)
      other = Sessions.generate_session_token(user)

      assert :ok == Sessions.delete_session_token(one)

      assert Sessions.get_user_by_session_token(other)
      assert TestRepo.aggregate(from(s in Session, where: s.user_id == ^user.id), :count) == 1
    end
  end

  # Shaped like a token this library would mint, belonging to nothing. `Secrets.token/0` is what
  # mints the real ones, so a change to their shape reaches this too.
  defp stranger, do: Secrets.token()
end
