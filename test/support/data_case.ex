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

  setup tags do
    pid = Sandbox.start_owner!(Ithibati.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
