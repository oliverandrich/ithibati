defmodule Ithibati.ConfigTest do
  @moduledoc """
  The settings this library cannot work out for itself, and what it says when they are wrong.

  Not async: it moves application environment that every other module reads.
  """
  use ExUnit.Case, async: false

  import Ithibati.DataCase, only: [delete_env: 2, put_env: 2]

  alias Ithibati.Config
  alias Ithibati.TestKey

  describe "user_schema/0" do
    test "unset, it says what to configure" do
      delete_env(:ithibati, :user_schema)

      assert_raise ArgumentError, ~r/config :ithibati, user_schema: MyApp.Accounts.User/, fn ->
        Config.user_schema()
      end
    end

    # Checked here rather than left to the caller: a module that is merely wrong otherwise fails
    # with `__ithibati__/1 is undefined`, which names neither this library nor the configuration.
    test "set to a module that is not an account schema, it says that" do
      put_env(:ithibati, user_schema: Ithibati.TestRepo)

      assert_raise ArgumentError, ~r/does not `use Ithibati.Schema.User`/, fn ->
        Config.user_schema()
      end
    end

    test "set to a module that does not exist at all, it says the same" do
      put_env(:ithibati, user_schema: Ithibati.NoSuchModule)

      assert_raise ArgumentError, ~r/does not `use Ithibati.Schema.User`/, fn ->
        Config.user_schema()
      end
    end

    test "set correctly, it answers the module" do
      assert Config.user_schema() == Ithibati.TestUser
    end
  end

  describe "invitation_schema/0" do
    # The one setting of the three that is allowed to be absent: an application that invites nobody
    # configures nothing, and every path that would read it is one it never takes.
    test "unset, it answers nothing rather than raising" do
      delete_env(:ithibati, :invitation_schema)

      assert Config.invitation_schema() == nil
    end

    test "set to a module that is not an invitation schema, it says that" do
      put_env(:ithibati, invitation_schema: Ithibati.TestUser)

      assert_raise ArgumentError, ~r/does not `use Ithibati.Schema.Invitation`/, fn ->
        Config.invitation_schema()
      end
    end

    # An invitation addressed to something an account can never be named by is a pair that cannot
    # work, and the moment it is read is a better one to find out than the moment somebody accepts.
    test "set to one addressed by a field the account schema does not use, it says that" do
      put_env(:ithibati, invitation_schema: Ithibati.MismatchedInvitation)

      assert_raise ArgumentError, ~r/invites by :username and .* is identified by :email/, fn ->
        Config.invitation_schema()
      end
    end

    test "set correctly, it answers the module" do
      assert Config.invitation_schema() == Ithibati.TestInvitation
    end
  end

  describe "users_key_type/0" do
    # The one place the account key type is written out rather than derived. Everything else — the
    # fixtures' primary keys, the tables the test migrations build, the column types the migration
    # assertions expect — comes from this value, so without a literal here both sides of each of
    # those comparisons move together, and a CI leg whose environment variable never arrived would
    # pass while testing the default a second time.
    test "is the type the environment asked for" do
      # Compared against a value read at *runtime* rather than written into each branch: the
      # configured type is a compile-time constant, so a literal on the right makes one branch
      # statically false, and Elixir says so — in a test file, where nothing turns that into an
      # error.
      expected =
        case System.get_env("ITHIBATI_USERS_KEY_TYPE") do
          "id" -> :id
          unset when unset in [nil, "", "binary_id"] -> :binary_id
        end

      assert Config.users_key_type() == expected
      assert TestKey.postgres_type() == %{binary_id: "uuid", id: "bigint"}[expected]
    end
  end

  describe "repo/0" do
    test "unset, it says what to configure" do
      delete_env(:ithibati, :repo)

      assert_raise ArgumentError, ~r/config :ithibati, repo: MyApp.Repo/, fn ->
        Config.repo()
      end
    end

    # Same reasoning as the schema above: otherwise the first query fails with
    # `__adapter__/0 is undefined`, which names neither this library nor the configuration.
    test "set to a module that is not a repo, it says that" do
      put_env(:ithibati, repo: Ithibati.TestUser)

      assert_raise ArgumentError, ~r/is not an Ecto repo/, fn -> Config.repo() end
    end

    test "set to a module that does not exist at all, it says the same" do
      put_env(:ithibati, repo: Ithibati.NoSuchModule)

      assert_raise ArgumentError, ~r/is not an Ecto repo/, fn -> Config.repo() end
    end

    test "set correctly, it answers the module" do
      assert Config.repo() == Ithibati.TestRepo
    end
  end
end
