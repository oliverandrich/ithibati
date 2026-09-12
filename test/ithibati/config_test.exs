defmodule Ithibati.ConfigTest do
  @moduledoc """
  The settings this library cannot work out for itself, and what it says when they are wrong.

  Not async: it moves application environment that every other module reads.
  """
  use ExUnit.Case, async: false

  alias Ithibati.Config

  setup do
    configured =
      Map.new([:user_schema, :repo], fn key ->
        {key, Application.fetch_env(:ithibati, key)}
      end)

    on_exit(fn ->
      Enum.each(configured, fn
        {key, {:ok, value}} -> Application.put_env(:ithibati, key, value)
        {key, :error} -> Application.delete_env(:ithibati, key)
      end)
    end)
  end

  describe "user_schema/0" do
    test "unset, it says what to configure" do
      Application.delete_env(:ithibati, :user_schema)

      assert_raise ArgumentError, ~r/config :ithibati, user_schema: MyApp.Accounts.User/, fn ->
        Config.user_schema()
      end
    end

    # Checked here rather than left to the caller: a module that is merely wrong otherwise fails
    # with `__ithibati__/1 is undefined`, which names neither this library nor the configuration.
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

  describe "repo/0" do
    test "unset, it says what to configure" do
      Application.delete_env(:ithibati, :repo)

      assert_raise ArgumentError, ~r/config :ithibati, repo: MyApp.Repo/, fn ->
        Config.repo()
      end
    end

    # Same reasoning as the schema above: otherwise the first query fails with
    # `__adapter__/0 is undefined`, which names neither this library nor the configuration.
    test "set to a module that is not a repo, it says that" do
      Application.put_env(:ithibati, :repo, Ithibati.TestUser)

      assert_raise ArgumentError, ~r/is not an Ecto repo/, fn -> Config.repo() end
    end

    test "set to a module that does not exist at all, it says the same" do
      Application.put_env(:ithibati, :repo, Ithibati.NoSuchModule)

      assert_raise ArgumentError, ~r/is not an Ecto repo/, fn -> Config.repo() end
    end

    test "set correctly, it answers the module" do
      assert Config.repo() == Ithibati.TestRepo
    end
  end
end
