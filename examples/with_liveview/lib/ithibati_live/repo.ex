defmodule IthibatiLive.Repo do
  use Ecto.Repo,
    otp_app: :ithibati_live,
    adapter: Ecto.Adapters.Postgres
end
