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

  # WebAuthn Level 2, §5.1.3: a relying party must reject a credential id longer than this. The
  # ceremony refuses one, and so does the write — a row stored past it is a passkey no sign-in can
  # ever reach, because the lookup short-circuits before it queries.
  @credential_id_max 1023

  @doc """
  How much of a label is kept. Ithibati cuts a longer one rather than refusing it, and the column
  itself has no limit.
  """
  def label_max, do: @label_max

  @doc "The longest credential id Ithibati stores."
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

  # Every write path goes through here, which is why the fallback lives here rather than at the one
  # caller that happens to assemble a credential: a person who leaves the nickname box alone sends a
  # blank string, not an absent one, and a nameless row in the passkey list is the case a fallback
  # exists for. There is deliberately no third source for the name.
  @fallback "Passkey"

  # `put_change/3` rather than `update_change/3`, which only fires for a field the changeset already
  # regards as changed — and casting `nil` over `nil` is not a change, so the row that needs the
  # fallback most is the one `update_change/3` skips.
  defp put_label(changeset) do
    put_change(changeset, :label, label(get_field(changeset, :label)))
  end

  @doc false
  # Public because a rename writes through `update_all`, which never builds a changeset — and the
  # cut and the fallback have to be the same rule on both paths or a list shows two kinds of row.
  #
  # Anything that is not a string gets the fallback rather than raising, which is what the enrolment
  # path does too: there `cast/3` refuses the value, `get_field/2` then answers `nil`, and the
  # fallback applies. A rename has no cast in front of it, and a form posting `name[]=x` hands over
  # a list.
  def label(label) when is_binary(label) do
    case label |> String.slice(0, @label_max) |> String.trim() do
      "" -> @fallback
      trimmed -> trimmed
    end
  end

  def label(_not_a_name), do: @fallback
end
