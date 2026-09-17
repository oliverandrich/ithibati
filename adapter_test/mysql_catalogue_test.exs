if Application.get_env(:ithibati, :probe_adapter) == Ecto.Adapters.MyXQL do
  defmodule Ithibati.MySQLCatalogueTest do
    use ExUnit.Case, async: false
    alias Ithibati.AdapterRepo, as: Repo
    alias Ithibati.Catalogue

    test "metadata reads exact key types and rejects prefix and composite uniqueness" do
      Repo.query!(
        "CREATE TABLE metadata_probe (id BIGINT PRIMARY KEY, code VARBINARY(32), other INT) ENGINE=InnoDB"
      )

      on_exit(fn -> Repo.query!("DROP TABLE metadata_probe") end)
      table = Catalogue.table(Repo, nil, "metadata_probe")
      assert {"bigint", true} = Catalogue.column(Repo, table, :id)
      assert {"varbinary(32)", false} = Catalogue.column(Repo, table, :code)
      Repo.query!("CREATE UNIQUE INDEX metadata_prefix ON metadata_probe(code(8))")
      Repo.query!("CREATE UNIQUE INDEX metadata_composite ON metadata_probe(code, other)")
      assert {"varbinary(32)", false} = Catalogue.column(Repo, table, :code)
      Repo.query!("CREATE UNIQUE INDEX metadata_full ON metadata_probe(code)")
      assert {"varbinary(32)", true} = Catalogue.column(Repo, table, :code)
      assert Catalogue.column(Repo, table, :absent) == nil
    end

    test "UUIDs require binary(16) and integer references preserve bigint signedness" do
      assert Catalogue.types(Repo, :binary_id) == ["binary(16)"]
      assert Catalogue.types(Repo, :id) == ["bigint", "bigint unsigned"]
      assert Catalogue.types(Repo, :binary) == ["varbinary(32)"]
      assert Catalogue.types(Repo, :utc_datetime_usec) == ["datetime(6)"]
    end

    test "missing tables and database prefixes are explicit" do
      assert Catalogue.table(Repo, nil, "not_present") == nil

      assert_raise ArgumentError, ~r/selected database/, fn ->
        Catalogue.table(Repo, "other", "app_users")
      end
    end
  end
end
