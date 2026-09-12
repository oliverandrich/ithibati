defmodule Ithibati.Schema.User do
  @moduledoc """
  What an account owes this library, added to the schema an application already owns.

      defmodule MyApp.Accounts.User do
        use Ecto.Schema
        use Ithibati.Schema.User

        import Ecto.Changeset

        schema "users" do
          ithibati_account()

          field :name, :string
          timestamps(type: :utc_datetime_usec)
        end

        def changeset(user, attrs) do
          user
          |> Ithibati.Schema.User.email_changeset(attrs)
          |> cast(attrs, [:name])
        end
      end

  One field and three associations, and the list is pinned in `Ithibati.Schema.UserTest`. The two
  columns the application creates are in the README; everything else about an account — roles,
  profile, preferences — stays the application's.
  """

  import Ecto.Changeset

  # RFC 5321's maximum for an address.
  @email_max 254

  # The regular expression the HTML specification publishes for `<input type=email>`. It is a
  # deliberate simplification of RFC 5322 — the specification says so itself — and it is the right
  # target here: this library never sends mail, so there is no deliverability to protect and an
  # address is a login identifier. A parser of the full grammar would accept quoted local parts with
  # spaces in them, which as a credential is a problem rather than a feature.
  #
  # Note what it does *not* require: a dot in the domain. `you@localhost` is a legitimate address on
  # a self-hosted instance, and a stricter pattern would lock it out.
  @format ~r"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$"

  @doc """
  Declares the field and associations this library needs. Call it inside your `schema` block.
  """
  defmacro ithibati_account do
    quote do
      field :email, :string

      has_many :passkeys, Ithibati.UserKey, foreign_key: :user_id
      has_many :recovery_codes, Ithibati.RecoveryCode, foreign_key: :user_id
      has_many :auth_tokens, Ithibati.UserToken, foreign_key: :user_id
    end
  end

  defmacro __using__(_opts) do
    quote do
      import Ithibati.Schema.User, only: [ithibati_account: 0]

      @doc """
      A name for this account that a passkey dialog can show, or `nil`.

      Returning `nil` is the ordinary answer, and this library then shows the address. Override it
      when the application has something better:

          def passkey_display_name(account), do: account.name

      No fallback is needed in an override — an account that has not filled the better name in
      returns `nil`, which is correct rather than broken.
      """
      def passkey_display_name(_account), do: nil

      defoverridable passkey_display_name: 1
    end
  end

  @doc """
  Casts and validates the address, and declares the constraint this library relies on.

  Takes a struct or a changeset and returns a changeset, so an application composes it into its own
  rather than being handed one that owns the account.
  """
  def email_changeset(account_or_changeset, attrs) do
    account_or_changeset
    |> cast(attrs, [:email])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> validate_format(:email, @format, message: "must be a valid email")
    |> validate_length(:email, max: @email_max)
    |> unique_constraint(:email)
  end

  @doc """
  The `name` and `displayName` a WebAuthn registration shows, for an account or for an address that
  does not have one yet.

  Both are derived here rather than by the caller, because the fallback is this library's to own: a
  consumer's `passkey_display_name/1` may answer `nil` and be right. The first registration on an
  instance has no account at all, which is why the second clause exists.
  """
  def credential_user(%module{} = account),
    do: %{
      name: account.email,
      display_name: module.passkey_display_name(account) || account.email
    }

  def credential_user(email) when is_binary(email), do: %{name: email, display_name: email}

  @doc "The address as it is stored: trimmed and lowercased."
  def normalize_email(nil), do: nil
  def normalize_email(email), do: email |> String.trim() |> String.downcase()

  @doc "The maximum length of an address — RFC 5321's. The column has to hold this many."
  def email_max, do: @email_max
end
