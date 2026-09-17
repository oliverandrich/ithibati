defmodule Ithibati.AdapterProbe do
  @moduledoc false
  import Ecto.Query
  alias Ithibati.AdapterEntry
  alias Ithibati.AdapterRepo

  def consume(id) do
    AdapterRepo.update_all(
      from(e in AdapterEntry, where: e.id == ^id and not e.consumed),
      set: [consumed: true]
    )
  end
end
