defmodule IthibatiEmail.Repo do
  use Ecto.Repo,
    otp_app: :ithibati_email,
    adapter: Ecto.Adapters.Postgres
end
