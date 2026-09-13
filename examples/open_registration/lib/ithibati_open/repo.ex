defmodule IthibatiOpen.Repo do
  use Ecto.Repo,
    otp_app: :ithibati_open,
    adapter: Ecto.Adapters.Postgres
end
