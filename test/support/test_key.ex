defmodule Ithibati.TestKey do
  @moduledoc """
  The account-table primary key this suite builds, in the three spellings the suite needs it in.

  Derived from `config :ithibati, users_key_type:` — the same value the library compiles its foreign
  keys from — so the account tables the tests stand up and the columns pointing at them cannot
  disagree. Why one run only ever sees one of the two: `config/config.exs`.
  """

  alias Ithibati.Config

  # A lookup rather than a `case`: the configured type is a compile-time constant, so a `case` over
  # it has exactly one reachable clause and the compiler says so — which `--warnings-as-errors`
  # then turns into a failing build on whichever leg is not the default.
  @spellings %{
    binary_id: %{column: :binary_id, postgres: "uuid"},
    id: %{column: :bigserial, postgres: "bigint"}
  }

  @doc "What an account schema's `@primary_key` says — all six of them say exactly this."
  def primary_key, do: {:id, Config.users_key_type(), autogenerate: true}

  @doc "What a migration's `add :id, …` says — `:id` is an integer *key*, which Postgres serialises."
  def column_type, do: spelling(Config.users_key_type(), :column)

  @doc "What Postgres calls the column afterwards, which is also what raw DDL has to name."
  def postgres_type, do: spelling(Config.users_key_type(), :postgres)

  @doc "The same two spellings for the key type this run was *not* compiled for."
  def other_column_type, do: spelling(other(), :column)

  @doc "See `other_column_type/0`."
  def other_postgres_type, do: spelling(other(), :postgres)

  defp other, do: Map.fetch!(%{binary_id: :id, id: :binary_id}, Config.users_key_type())

  defp spelling(type, key), do: @spellings |> Map.fetch!(type) |> Map.fetch!(key)
end
