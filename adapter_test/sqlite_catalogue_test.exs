if Application.get_env(:ithibati, :probe_adapter) == Ecto.Adapters.SQLite3 do
  defmodule Ithibati.SQLiteCatalogueTest do
    use Ithibati.AdapterIdentityCase
    alias Ithibati.Catalogue
    alias Ithibati.Doctor

    test "doctor accepts SQLite and verifies the migrated schema" do
      results = Doctor.examine(:ithibati)

      for subject <- [
            "the database adapter",
            "the repo answers",
            "this library's tables",
            "config :ithibati, users_key_type:",
            "the identifier's unique index",
            "the invitation table"
          ] do
        assert {^subject, {:ok, _}} = List.keyfind!(results, subject, 0)
      end
    end

    test "doctor reports disabled foreign keys before dependent checks" do
      Repo.checkout(fn ->
        Repo.query!("PRAGMA foreign_keys = OFF")

        try do
          results = Doctor.examine(:ithibati)
          assert {_, {:error, detail}} = List.keyfind!(results, "the repo answers", 0)
          assert detail =~ "foreign_keys"
          assert {_, {:skip, _}} = List.keyfind!(results, "this library's tables", 0)
        after
          Repo.query!("PRAGMA foreign_keys = ON")
        end
      end)
    end

    test "metadata distinguishes full, partial, expression and composite uniqueness" do
      Repo.query!("CREATE TABLE metadata_probe (id INTEGER PRIMARY KEY, code TEXT, other TEXT)")
      on_exit(fn -> Repo.query!("DROP TABLE metadata_probe") end)
      table = Catalogue.table(Repo, nil, "metadata_probe")
      assert {"integer", true} = Catalogue.column(Repo, table, :id)
      assert {"text", false} = Catalogue.column(Repo, table, :code)
      assert nil == Catalogue.column(Repo, table, :absent)

      Repo.query!(
        "CREATE UNIQUE INDEX metadata_partial ON metadata_probe(code) WHERE code IS NOT NULL"
      )

      Repo.query!("CREATE UNIQUE INDEX metadata_expression ON metadata_probe(lower(code))")
      Repo.query!("CREATE UNIQUE INDEX metadata_composite ON metadata_probe(code, other)")
      assert {"text", false} = Catalogue.column(Repo, table, :code)
      Repo.query!("CREATE UNIQUE INDEX metadata_full ON metadata_probe(code)")
      assert {"text", true} = Catalogue.column(Repo, table, :code)
    end

    test "missing tables and unsupported schema prefixes have explicit results" do
      assert nil == Catalogue.table(Repo, nil, "no_such_table")

      assert_raise ArgumentError, ~r/unprefixed main database/, fn ->
        Catalogue.table(Repo, "other", "app_users")
      end
    end

    test "key validation rejects a mismatched storage type" do
      type =
        if Application.get_env(:ithibati, :users_key_type, :binary_id) == :id,
          do: "TEXT",
          else: "INTEGER"

      Repo.query!("CREATE TABLE wrong_key (id #{type} PRIMARY KEY)")
      on_exit(fn -> Repo.query!("DROP TABLE wrong_key") end)
      table = Catalogue.table(Repo, nil, "wrong_key")
      assert {:error, detail} = Catalogue.key_column(Repo, table, "wrong_key", :id)
      assert detail =~ "Configure the type"
    end

    test "table and index names are values, including punctuation and quotes" do
      Repo.query!(~s|CREATE TABLE "quoted' table" ("key' value" TEXT PRIMARY KEY)|)
      on_exit(fn -> Repo.query!(~s|DROP TABLE "quoted' table"|) end)
      table = Catalogue.table(Repo, nil, "quoted' table")
      assert {"text", true} = Catalogue.column(Repo, table, "key' value")
    end
  end
end
