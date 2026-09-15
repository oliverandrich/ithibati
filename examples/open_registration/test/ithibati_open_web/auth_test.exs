defmodule IthibatiOpenWeb.AuthTest do
  @moduledoc """
  The two answers this handler gives, and the difference between them.

  "That name is taken" and "that is not a name" are decided in different places — the unique index
  and the format — and a page that confuses them tells somebody a name nobody holds is somebody
  else's.
  """
  use IthibatiOpen.DataCase, async: true

  alias IthibatiOpen.Accounts.User
  alias IthibatiOpenWeb.Auth

  defp key_attrs do
    %{key_id: :crypto.strong_rand_bytes(16), public_key: :crypto.strong_rand_bytes(64)}
  end

  defp conn, do: Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})

  test "a free username is approved, normalised the way it will be stored" do
    assert {:ok, "ada"} = Auth.registration_subject(conn(), %{"username" => "  Ada  "})
  end

  test "and registering it creates the account" do
    assert {:ok, _conn} = Auth.register(conn(), key_attrs(), "ada", %{})

    assert Repo.get_by(User, username: "ada")
  end

  # The expensive order to get wrong: approving it here means a passkey dialog, a credential the
  # authenticator now keeps, and only then a refusal. `registration_subject/2` is asked before any
  # of that, which is the whole reason the callback exists.
  test "a name the schema could never store is refused before any ceremony starts" do
    for value <- ["Alice Smith!", "alice.smith", String.duplicate("a", 31), ""] do
      assert {:error, :invalid_username} =
               Auth.registration_subject(conn(), %{"username" => value}),
             "approved #{inspect(value)}"
    end
  end

  test "and a request naming no username at all is refused too" do
    assert {:error, :username_required} = Auth.registration_subject(conn(), %{})
  end

  # Two people can pick one name in the same second, so the index decides this and not a lookup
  # beforehand — but the answer has to say *taken*, not the format answer.
  # `register/4` takes the subject from the session, not from this request, so it is worth asking
  # what it answers for one that should never have got there. "Taken" would be a lie about a name
  # nobody holds — and the two errors come from different places, so only the constraint can say.
  test "a subject the schema refuses is answered as malformed, not as taken" do
    assert {:error, :invalid_username} = Auth.register(conn(), key_attrs(), "Not A Name!", %{})
  end

  test "a name somebody already has is refused as taken, not as malformed" do
    {:ok, _conn} = Auth.register(conn(), key_attrs(), "ada", %{})

    assert {:error, :username_taken} = Auth.register(conn(), key_attrs(), "ada", %{})
  end
end
