defmodule Ithibati.AdapterStorageTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ithibati.AdapterEntry
  alias Ithibati.AdapterRepo, as: Repo

  setup do
    Repo.delete_all(AdapterEntry)
    on_exit(fn -> Repo.delete_all(AdapterEntry) end)
    :ok
  end

  test "the probe migration rolls down and can be applied again" do
    try do
      assert :ok = Ecto.Migrator.down(Repo, 1, Ithibati.AdapterMigration, log: false)
      assert {:error, _missing_table} = Repo.query("SELECT id FROM adapter_entries")
    after
      assert :ok = Ecto.Migrator.up(Repo, 1, Ithibati.AdapterMigration, log: false)
    end

    assert Repo.all(AdapterEntry) == []
  end

  test "UUIDs, large integer keys, binary values and microseconds survive a round trip" do
    now = ~U[2026-09-17 12:34:56.123456Z]
    bytes = :binary.copy(<<0, 255, 128>>, 341)
    entry = Repo.insert!(%AdapterEntry{owner_id: 4_294_967_296, bytes: bytes, seen_at: now})
    assert {:ok, _} = Ecto.UUID.cast(entry.id)
    assert Repo.get!(AdapterEntry, entry.id) == entry
    assert entry.seen_at == now
    assert entry.bytes == bytes
    assert entry.owner_id == 4_294_967_296
  end

  test "rollback removes the write and a following transaction still commits" do
    assert {:error, :probe} =
             Repo.transaction(fn ->
               Repo.insert!(%AdapterEntry{bytes: <<1>>})
               Repo.rollback(:probe)
             end)

    refute Repo.exists?(AdapterEntry)
    assert {:ok, _} = Repo.transaction(fn -> Repo.insert!(%AdapterEntry{bytes: <<2>>}) end)
    assert Repo.exists?(AdapterEntry)
  end

  test "conditional writes report one winner, including a repeated consume" do
    entry = Repo.insert!(%AdapterEntry{bytes: <<3>>})
    assert {1, nil} = Ithibati.AdapterProbe.consume(entry.id)
    assert {0, nil} = Ithibati.AdapterProbe.consume(entry.id)
  end

  test "an unchanged update counts the matching row" do
    entry = Repo.insert!(%AdapterEntry{bytes: <<4>>})

    assert {1, nil} =
             Repo.update_all(from(e in AdapterEntry, where: e.id == ^entry.id),
               set: [consumed: false]
             )
  end

  test "a duplicate binary value becomes a unique changeset error" do
    Repo.insert!(%AdapterEntry{bytes: <<0, 255, 0>>})

    changeset =
      %AdapterEntry{}
      |> Ecto.Changeset.change(bytes: <<0, 255, 0>>)
      |> Ecto.Changeset.unique_constraint(:bytes)

    assert {:error, changeset} = Repo.insert(changeset)
    assert {_message, details} = changeset.errors[:bytes]
    assert details[:constraint] == :unique
  end

  test "binary uniqueness includes the final byte" do
    prefix = :binary.copy(<<255>>, 1022)
    Repo.insert!(%AdapterEntry{bytes: prefix <> <<0>>})
    Repo.insert!(%AdapterEntry{bytes: prefix <> <<1>>})
    assert Repo.aggregate(AdapterEntry, :count) == 2
  end
end
