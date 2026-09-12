defmodule Ithibati.DataCase do
  @moduledoc """
  Test case for anything that touches the database.

  Each test runs inside a transaction that is rolled back afterwards, so tests may run concurrently
  and leave nothing behind. A module marked `async: false` gets a shared connection instead, which is
  what a test driving a second process needs.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Ecto.Changeset
      import Ecto.Query

      import Ithibati.DataCase

      alias Ithibati.GuestUser
      alias Ithibati.MemberUser
      alias Ithibati.NamedUser
      alias Ithibati.TestCredentials
      alias Ithibati.TestRepo
      alias Ithibati.TestUser
    end
  end

  @doc """
  The messages a changeset carries, as a map of field to a list of strings.

  Ecto keeps them as `{message, opts}` so that a count or a limit can be interpolated late; this
  does that interpolation, which is what the assertion wants to read.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  An account, for tests that need one to hang something off rather than to examine.

  Four test files were each building this by hand; what they all wanted was a row with a unique
  address.
  """
  def user_fixture(attrs \\ %{}) do
    address = Map.get(attrs, :email, "someone-#{System.unique_integer([:positive])}@example.test")

    {:ok, user} =
      %Ithibati.TestUser{}
      |> Ithibati.TestUser.changeset(Map.put(attrs, :email, address))
      |> Ithibati.TestRepo.insert()

    user
  end

  @doc """
  A credential row belonging to `user`.

  Its key material is random bytes and verifies nothing, which is all a test about *rows* needs —
  one that counts credentials, or checks which are excluded from a registration.
  `Ithibati.TestCredentials.credential/0` is the real pair, and it costs a P-256 key generation;
  reach for it only where a signature or an attestation is actually checked.
  """
  def key_fixture(user, attrs \\ %{}) do
    defaults = %{
      user_id: user.id,
      key_id: :crypto.strong_rand_bytes(16),
      public_key: :erlang.term_to_binary(%{stand_in: :crypto.strong_rand_bytes(32)})
    }

    Ithibati.TestRepo.insert!(
      Ithibati.UserKey.changeset(%Ithibati.UserKey{}, Map.merge(defaults, attrs))
    )
  end

  setup tags do
    pid = Sandbox.start_owner!(Ithibati.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
