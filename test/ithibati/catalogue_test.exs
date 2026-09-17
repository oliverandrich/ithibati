defmodule Ithibati.CatalogueTest do
  use Ithibati.DataCase, async: true
  alias Ithibati.Catalogue

  test "PostgreSQL table references resolve column metadata" do
    TestRepo.query!("CREATE TEMP TABLE catalogue_contract (id uuid PRIMARY KEY)")
    oid = Catalogue.table(TestRepo, nil, "catalogue_contract")
    assert is_integer(oid)
    assert {"uuid", true} = Catalogue.column(TestRepo, oid, :id)
    assert Catalogue.column(TestRepo, oid, :absent) == nil
    assert Catalogue.table(TestRepo, nil, "catalogue_missing") == nil
  end

  test "PostgreSQL storage type names remain stable" do
    assert Catalogue.types(TestRepo, :binary_id) == ["uuid"]
    assert Catalogue.types(TestRepo, :id) == ["smallint", "integer", "bigint"]
    assert Catalogue.types(TestRepo, :binary) == ["bytea"]

    assert Catalogue.types(TestRepo, :utc_datetime_usec) ==
             ["timestamp without time zone", "timestamp(6) without time zone"]
  end
end
