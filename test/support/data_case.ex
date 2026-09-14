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
      alias Ithibati.NamedIndexUser
      alias Ithibati.NamedUser
      alias Ithibati.OptedOutUser
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
    {:ok, user} = attrs |> user_changeset() |> Ithibati.TestRepo.insert()

    user
  end

  @doc """
  The same account as a changeset, for a test that wants to put it in an `Ecto.Multi` rather than in
  the database.
  """
  def user_changeset(attrs \\ %{}) do
    address = Map.get(attrs, :email, "someone-#{System.unique_integer([:positive])}@example.test")

    Ithibati.TestUser.changeset(%Ithibati.TestUser{}, Map.put(attrs, :email, address))
  end

  @doc """
  A credential row belonging to `user`.

  Its key material is random bytes and verifies nothing, which is all a test about *rows* needs —
  one that counts credentials, or checks which are excluded from a registration.
  `Ithibati.TestCredentials.credential/0` is the real pair, and it costs a P-256 key generation;
  reach for it only where a signature or an attestation is actually checked.
  """
  def key_fixture(user, attrs \\ %{}) do
    defaults = Map.put(stand_in_key(), :user_id, user.id)

    Ithibati.TestRepo.insert!(
      Ithibati.UserKey.changeset(%Ithibati.UserKey{}, Map.merge(defaults, attrs))
    )
  end

  @doc """
  Stand-in credential material: random bytes that verify nothing.

  What a test about *rows* needs, and three modules were each writing it out. A test that checks a
  signature or an attestation wants `Ithibati.TestCredentials.credential/0` instead, which costs a
  P-256 key generation.
  """
  def stand_in_key do
    %{
      key_id: :crypto.strong_rand_bytes(16),
      public_key: :erlang.term_to_binary(%{stand_in: :crypto.strong_rand_bytes(32)})
    }
  end

  @doc """
  Compiles a schema that uses one of this library's macros, so a test can watch it be refused.

  Each probe gets a name of its own: a module compiled twice warns about redefinition. `body` is what
  goes above the schema block — the `use` line under test — `inside:` is what goes in it, and
  `after_schema:` is what follows.

  Written as source and compiled rather than spelled out as a `defmodule`, so that what a test varies
  is an argument and the rest does not have to be read again.
  """
  def probe(name, body, opts \\ []) do
    [{module, _bytecode} | _] =
      Code.compile_string("""
      defmodule Ithibati.Probe#{name} do
        use Ecto.Schema
        #{body}

        @primary_key {:id, :binary_id, autogenerate: true}
        schema "probes" do
          #{opts[:inside]}
        end

        #{opts[:after_schema]}
      end
      """)

    module
  end

  @doc """
  Moves application environment for the duration of a test, and puts it back.

  Both `:ithibati`'s own settings and `:wax_`'s are global state: a module using this is
  `async: false`, and the restore is what keeps a leaked key out of every other module. A key that
  was not set before is **removed** again rather than set to `nil` — the two are different answers
  to `fetch_env/2`, and a library that refuses an unset setting sees the second one as configured.
  """
  # `Enum.each` rather than a comprehension: this is often the last expression of a `setup` block,
  # which accepts `:ok`, a map or a keyword list — and not a list of `:ok`s.
  def put_env(app, pairs) when is_list(pairs) do
    Enum.each(pairs, fn {key, value} -> put_env(app, key, value) end)
  end

  @doc "The same for a single setting, where the key is computed rather than written out."
  def put_env(app, key, value) do
    restore_later(app, key)
    Application.put_env(app, key, value)
  end

  @doc """
  Removes a setting for the duration of a test, and puts it back.

  Its own function rather than a sentinel value passed to `put_env/2`: the settings these tests move
  are themselves bare atoms, so any sentinel would one day be somebody's real value and delete a key
  they meant to set.
  """
  def delete_env(app, key) do
    restore_later(app, key)
    Application.delete_env(app, key)
  end

  defp restore_later(app, key) do
    previous = Application.fetch_env(app, key)
    ExUnit.Callbacks.on_exit(fn -> restore_env(app, key, previous) end)
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)

  setup tags do
    pid = Sandbox.start_owner!(Ithibati.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
