defmodule Ithibati.AdapterRepo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :ithibati,
    adapter: Application.compile_env!(:ithibati, :probe_adapter)
end

defmodule Ithibati.AdapterEntry do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "adapter_entries" do
    field :owner_id, :integer
    field :bytes, :binary
    field :seen_at, :utc_datetime_usec
    field :consumed, :boolean, default: false
  end
end

defmodule Ithibati.AdapterMigration do
  @moduledoc false
  use Ecto.Migration

  def change do
    binary_options =
      if repo().__adapter__() == Ecto.Adapters.MyXQL,
        do: [size: 1023, null: false],
        else: [null: false]

    create table(:adapter_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_id, :bigint
      add :bytes, :binary, binary_options
      add :seen_at, :utc_datetime_usec
      add :consumed, :boolean, null: false, default: false
    end

    create unique_index(:adapter_entries, [:bytes])
  end
end
