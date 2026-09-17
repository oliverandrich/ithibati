defmodule Ithibati.Bootstrap do
  @moduledoc """
  Stores the one-time bootstrap claim and the account that made it.

  A unique index on `:claimed` permits one claim through `Ithibati.Identity.Instance.claim/2`.
  The row belongs to Ithibati so its migration maintains that constraint.

  Deleting the account nulls `user_id` while preserving the claim. Initial setup therefore stays
  closed after the first account is removed. Use `Ithibati.Identity.Instance` to read or claim
  this state.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Ithibati.Config

  @primary_key {:id, :binary_id, autogenerate: true}

  schema Config.table("bootstrap") do
    # Always true. It exists so a unique index can say *at most one row*, which is not otherwise
    # something a table can state about itself.
    field :claimed, :boolean, default: true
    field :user_id, Config.users_key_type()

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a bootstrap changeset with the account reference and database constraints.

  This function does not insert the row. An insert can report a unique-constraint error on
  `:claimed` or a foreign-key error on `:user_id`. Application registration flows should use
  `Ithibati.Identity.Instance.claim/2` to handle these within their transaction.
  """
  def changeset(bootstrap, attrs) do
    bootstrap
    |> cast(attrs, [:user_id])
    |> unique_constraint(:claimed)
    |> foreign_key_constraint(:user_id)
  end
end
