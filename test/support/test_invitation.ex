defmodule Ithibati.TestInvitation do
  @moduledoc """
  Stands in for the invitation schema a consuming application owns: it uses the library's macro and
  adds the one field that says what is being invited *to*, which is the half this library must not
  know about.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.Invitation

  use Invitation, identifier: :email, format: Identifier.email_format()

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "invitations" do
    ithibati_invitation()

    field :role, Ecto.Enum, values: [:admin, :author]

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(invitation, attrs, opts \\ []) do
    invitation
    |> invitation_changeset(attrs, opts)
    |> cast(attrs, [:role])
    |> validate_required([:role])
  end
end

defmodule Ithibati.MismatchedInvitation do
  @moduledoc """
  An invitation addressed by something an account is not identified by.

  Nothing is ever written through it: what a test asks of it is what the macro recorded, which is
  the thing `Ithibati.Config.invitation_schema/0` compares against the account schema.
  """
  use Ecto.Schema

  alias Ithibati.Schema.Invitation

  use Invitation, identifier: :username

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "invitations" do
    ithibati_invitation()
  end
end

defmodule Ithibati.OddInvitation do
  @moduledoc """
  An invitation whose primary key is not called `id`.

  The table is the application's, so its primary key is the application's to name — and a query that
  wrote `id` out by hand would work everywhere except here.
  """
  use Ecto.Schema

  alias Ithibati.Schema.Invitation

  use Invitation, identifier: :email, unique_index: false

  @primary_key {:invitation_id, :binary_id, autogenerate: true}

  schema "odd_invitations" do
    ithibati_invitation()
  end
end
