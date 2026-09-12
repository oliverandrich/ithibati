defmodule Ithibati.UserKey do
  @moduledoc """
  One WebAuthn credential: the public half of a passkey, and the label a person recognises it by.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Ithibati.Config

  # The label is supplied rather than generated — either the authenticator's own name or one the
  # browser sent with the registration — and it arrives from a hook's params, where a validation
  # error has nowhere to appear and would fail the whole registration over a nickname. So it is cut
  # rather than refused. The column takes any length; this is what a person can read in a list.
  @label_max 100

  @primary_key {:id, :binary_id, autogenerate: true}

  schema Config.table("keys") do
    field :key_id, :binary
    field :public_key, :binary
    field :label, :string
    field :last_used_at, :utc_datetime_usec
    field :user_id, Config.users_key_type()

    timestamps(type: :utc_datetime_usec)
  end

  @doc "How much of a label is kept. A longer one is cut, not refused; the column has no limit."
  def label_max, do: @label_max

  @doc false
  def changeset(user_key, attrs) do
    user_key
    |> cast(attrs, [:key_id, :public_key, :label, :last_used_at, :user_id])
    |> validate_required([:key_id, :public_key, :user_id])
    |> update_change(:label, &cut/1)
    |> unique_constraint(:key_id)
    |> foreign_key_constraint(:user_id)
  end

  defp cut(nil), do: nil
  defp cut(label), do: label |> String.slice(0, @label_max) |> String.trim_trailing()
end
