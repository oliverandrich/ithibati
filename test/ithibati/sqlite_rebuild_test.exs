defmodule Ithibati.Migration.SQLiteRebuildTest do
  @moduledoc """
  The rewrite of a stored SQLite table definition, without a database.

  Only the column's own NOT NULL constraint may change. The same words inside a CHECK expression
  or a string default belong to something else.
  """
  use ExUnit.Case, async: true

  alias Ithibati.Migration.SQLiteRebuild

  @table ~s|CREATE TABLE "invitations" ("id" TEXT PRIMARY KEY, "email" TEXT NOT NULL, "note" TEXT)|

  test "drops and restores the column's NOT NULL" do
    assert {:ok, open} = SQLiteRebuild.rewrite(@table, "email", true)
    assert open == ~s|("id" TEXT PRIMARY KEY, "email" TEXT, "note" TEXT)|
    assert {:ok, closed} = SQLiteRebuild.rewrite("CREATE TABLE t " <> open, "email", false)
    assert closed == ~s|("id" TEXT PRIMARY KEY, "email" TEXT NOT NULL, "note" TEXT)|
  end

  test "leaves a column alone that already is what is asked" do
    assert SQLiteRebuild.rewrite(@table, "note", true) == :unchanged
    assert SQLiteRebuild.rewrite(@table, "email", false) == :unchanged
  end

  test "ignores NOT NULL inside a CHECK expression or a string default" do
    table =
      ~s|CREATE TABLE t ("email" TEXT DEFAULT 'NOT NULL' CHECK (email IS NOT NULL OR 1), "id" TEXT)|

    assert {:ok, closed} = SQLiteRebuild.rewrite(table, "email", false)
    assert closed =~ ~s|CHECK (email IS NOT NULL OR 1) NOT NULL, "id" TEXT)|
    assert SQLiteRebuild.rewrite(table, "email", true) == :unchanged
  end

  test "keeps table options after the column list" do
    assert {:ok, open} =
             SQLiteRebuild.rewrite(
               ~s|CREATE TABLE t ("email" TEXT NOT NULL) STRICT|,
               "email",
               true
             )

    assert open == ~s|("email" TEXT) STRICT|
  end
end
