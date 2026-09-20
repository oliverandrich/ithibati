defmodule Ithibati.MigrationOptionsTest do
  @moduledoc """
  What `Ithibati.Migration` refuses before it touches a database.

  Every wrong value here fails silently or far away — a version this release does not know reaches
  no clause, and a starting point at or above it builds nothing at all while Ecto records the
  migration as applied. Each is refused where it is passed instead.
  """
  use ExUnit.Case, async: true

  alias Ithibati.Migration

  test "an unpinned call" do
    assert_raise ArgumentError, ~r/version: is required/, fn -> Migration.up([]) end
  end

  test "a version this release does not know" do
    assert_raise ArgumentError, ~r/version must be 1\.\.3/, fn ->
      Migration.up(version: Migration.current_version() + 1)
    end
  end

  test "a starting point at or above the version, which would build nothing at all" do
    assert_raise ArgumentError, ~r/from must be 0\.\.0/, fn ->
      Migration.up(version: 1, from: 1)
    end
  end

  # The one line in the migration that is not obvious, and the branch no migration in this suite
  # takes: Ecto renders `:id` as `integer`, while the Phoenix default it stands for is `bigserial`.
  # A foreign key declared `integer` holds accounts up to two billion and then fails on insert.
  describe "the key type a foreign key is declared with" do
    test "an integer account key becomes bigint, not integer" do
      assert Migration.reference_type(:id) == :bigint
    end

    test "anything else is passed through" do
      assert Migration.reference_type(:binary_id) == :binary_id
    end
  end
end
