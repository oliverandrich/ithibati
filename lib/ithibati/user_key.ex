defmodule Ithibati.UserKey do
  @moduledoc """
  Stores a passkey's credential ID, serialized public key, label and last-use timestamp.

  Use `Ithibati.Identity.Passkeys` to enrol, list, rename and revoke credentials. A blank or absent
  label is stored as `"Passkey"`; labels are limited to `label_max/0` graphemes.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Ithibati.Config

  # Truncate display labels instead of rejecting otherwise valid enrolment over a long nickname.
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

  # Verification, storage and lookup share this credential-ID byte limit.
  @credential_id_max 1023

  @doc """
  Returns the maximum label length in graphemes.

  Enrolment and rename truncate labels to this length before trimming whitespace. The database
  column itself has no length limit.
  """
  def label_max, do: @label_max

  @doc "Returns the maximum stored credential-ID length in bytes."
  def credential_id_max, do: @credential_id_max

  @doc false
  def changeset(user_key, attrs) do
    user_key
    |> cast(attrs, [:key_id, :public_key, :label, :last_used_at, :user_id])
    |> validate_required([:key_id, :public_key, :user_id])
    |> validate_length(:key_id, max: @credential_id_max, count: :bytes)
    |> put_label()
    |> unique_constraint(:key_id)
    |> foreign_key_constraint(:user_id)
  end

  # Use the same fallback for a missing or blank label during enrolment and rename.
  @fallback "Passkey"

  # `update_change/3` skips an unchanged nil field. `put_change/3` also supplies the fallback
  # when no label was cast.
  defp put_label(changeset) do
    put_change(changeset, :label, label(get_field(changeset, :label)))
  end

  @doc false
  # Renaming uses `update_all/2` and bypasses the changeset, so both paths call this normalizer.
  # Non-string rename input gets the fallback; enrolment still retains any cast validation error.
  def label(label) when is_binary(label) do
    case label |> String.slice(0, @label_max) |> String.trim() do
      "" -> @fallback
      trimmed -> trimmed
    end
  end

  def label(_not_a_name), do: @fallback
end
