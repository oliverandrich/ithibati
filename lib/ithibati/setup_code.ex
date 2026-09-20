defmodule Ithibati.SetupCode do
  @moduledoc "Stores the current operator-code digest for a protected first account claim."
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema Ithibati.Config.table("setup_codes") do
    field :digest, :binary
    timestamps(type: :utc_datetime_usec)
  end
end
