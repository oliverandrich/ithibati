defmodule Ithibati.ConfigTest do
  @moduledoc """
  The one setting this library cannot work out for itself, and what it says when it is wrong.

  Not async: it moves application environment that every other module reads.
  """
  use ExUnit.Case, async: false

  alias Ithibati.Config

  setup do
    configured = Application.get_env(:ithibati, :user_schema)
    on_exit(fn -> Application.put_env(:ithibati, :user_schema, configured) end)
  end

  test "unset, it says what to configure" do
    Application.delete_env(:ithibati, :user_schema)

    assert_raise ArgumentError, ~r/config :ithibati, user_schema: MyApp.Accounts.User/, fn ->
      Config.user_schema()
    end
  end

  # Checked here rather than left to the caller: a module that is merely wrong otherwise fails with
  # `__ithibati__/1 is undefined`, which names neither this library nor the configuration.
  test "set to a module that is not an account schema, it says that" do
    Application.put_env(:ithibati, :user_schema, Ithibati.TestRepo)

    assert_raise ArgumentError, ~r/does not `use Ithibati.Schema.User`/, fn ->
      Config.user_schema()
    end
  end

  test "set to a module that does not exist at all, it says the same" do
    Application.put_env(:ithibati, :user_schema, Ithibati.NoSuchModule)

    assert_raise ArgumentError, ~r/does not `use Ithibati.Schema.User`/, fn ->
      Config.user_schema()
    end
  end

  test "set correctly, it answers the module" do
    assert Config.user_schema() == Ithibati.TestUser
  end
end
