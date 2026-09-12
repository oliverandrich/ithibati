defmodule Ithibati.TestRepo do
  @moduledoc """
  The repo this library's own tests run against.

  It lives under `test/support` rather than in `lib/`, and that is the whole point of the library's
  design: a consumer brings its own repo and the library is told which one. Shipping a repo would
  mean owning a database, which is exactly what this does not do.
  """
  use Ecto.Repo, otp_app: :ithibati, adapter: Ecto.Adapters.Postgres
end
