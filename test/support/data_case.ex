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

      alias Ithibati.TestRepo
      alias Ithibati.TestUser
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Ithibati.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
