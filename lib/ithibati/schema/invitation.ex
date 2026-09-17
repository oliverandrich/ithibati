defmodule Ithibati.Schema.Invitation do
  @moduledoc """
  Adds invitation-token fields and validation to an application-owned schema.

  Declare the invitation's identifier and add your own fields for what accepting it grants:

      defmodule MyApp.Accounts.Invitation do
        use Ecto.Schema
        import Ecto.Changeset

        alias Ithibati.Schema.Identifier
        alias Ithibati.Schema.Invitation

        use Invitation, identifier: :email, format: Identifier.email_format()

        schema "invitations" do
          ithibati_invitation()

          field :role, Ecto.Enum, values: [:admin, :author]
          belongs_to :site, MyApp.Sites.Site

          timestamps(type: :utc_datetime_usec)
        end

        def changeset(invitation, attrs, opts \\ []) do
          invitation
          |> invitation_changeset(attrs, opts)
          |> cast(attrs, [:role, :site_id])
          |> validate_required([:role, :site_id])
        end
      end

  The options match `Ithibati.Schema.User`: required `:identifier`, optional `:format` and
  `:format_message`, plus `:constraint_name` and `:unique_index`. On invitations, the index
  options refer to `token_hash`, not the identifier. Non-identifier options can be module
  attributes declared before `use`; explicit `nil` values are rejected.

  The identifier field must match the configured account schema's identifier. That agreement is
  checked when `Ithibati.Config.invitation_schema/0` reads the application configuration.

  Call `ithibati_invitation/0` inside the schema. The macro generates `invitation_changeset/3`
  and `__ithibati_invitation__/1`; defining either yourself is rejected at compile time.
  [Invitations](invitations.md) covers the table, token index and acceptance transaction.
  """

  import Ecto.Changeset
  import Ecto.Query

  @default_days 7

  alias Ithibati.Config
  alias Ithibati.Identity.Secrets
  alias Ithibati.Schema.Identifier

  @doc """
  Declares invitation fields inside the application's schema block.

  Adds the configured identifier as `:string`, `:token_hash` as `:binary`, and
  `:expires_at` and `:accepted_at` as `:utc_datetime_usec`. It also adds a virtual `:token`
  string for the plaintext token returned when a valid new invitation is built.

  Only the digest is stored. Retain the plaintext token to deliver the invitation link;
  reloading the row does not recover it.
  """
  defmacro ithibati_invitation do
    quote do
      @ithibati_given ||
        raise(
          ArgumentError,
          "ithibati_invitation/0 needs `use Ithibati.Schema.Invitation` above it"
        )

      @ithibati_declared @ithibati_given.identifier

      field @ithibati_declared, :string

      # Not stored, and the only way the secret leaves: a changeset cannot answer with a second
      # value, and a caller who has to mint the token himself is a caller who will forget to.
      field :token, :string, virtual: true

      field :token_hash, :binary
      field :expires_at, :utc_datetime_usec
      field :accepted_at, :utc_datetime_usec
    end
  end

  defmacro __using__(opts) do
    given = Identifier.options!(opts, __MODULE__)

    quote do
      import Ithibati.Schema.Invitation, only: [ithibati_invitation: 0]

      @before_compile Ithibati.Schema.Invitation

      # Evaluate deferred checks here, where the consumer's module attributes exist.
      @ithibati_given unquote({:%{}, [], Map.to_list(given)})
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    Identifier.refuse_shadowing!(
      env,
      [__ithibati_invitation__: 1, invitation_changeset: 3],
      __MODULE__
    )

    field = Identifier.declared!(env, __MODULE__, "ithibati_invitation/0")
    given = env.module |> Module.get_attribute(:ithibati_given) |> Map.put(:identifier, field)

    quote do
      @doc """
      Returns metadata declared by `use Ithibati.Schema.Invitation`.

        * `:identifier` — the invitee identifier field name.
        * `:constraint` — the configured token-hash index name, or `nil` for Ecto's default name.
        * `:unique_index` — whether Ithibati should create that index.
      """
      def __ithibati_invitation__(:identifier), do: unquote(field)
      def __ithibati_invitation__(:constraint), do: unquote(given.constraint)
      def __ithibati_invitation__(:unique_index), do: unquote(given.unique_index)

      @doc """
      Returns a changeset with the identifier validated, a token prepared and an expiry set.

      Accepts a struct or changeset and an attributes map. The identifier is trimmed, lowercased,
      required, checked against any configured format and limited to 254 graphemes. A valid changed
      identifier is checked against existing accounts; a match adds a `:unclaimed` validation error.
      That lookup is advisory: the account's unique index remains the final guarantee.

      For a valid new invitation without a stored token digest, the changeset receives a plaintext
      `:token` and its `:token_hash`. Updating an invitation with a stored digest preserves its token.

      `:days` sets expiry relative to the current time. It defaults to seven days when no expiry
      exists. Passing it for an existing invitation updates the expiry; omitting it preserves the
      stored expiry. The token-hash unique constraint is declared on the returned changeset.
      """
      def invitation_changeset(invitation_or_changeset, attrs, opts \\ []) do
        # Written out because this is a quote: Elixir resolves aliases where the code is *written*,
        # so an alias here would be this module's and not the consumer's.
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        Ithibati.Schema.Invitation.__changeset__(
          invitation_or_changeset,
          attrs,
          opts,
          unquote(Macro.escape(given))
        )
      end
    end
  end

  @doc false
  def __changeset__(invitation_or_changeset, attrs, opts, given) do
    invitation_or_changeset
    |> Identifier.steps(attrs, given.identifier, given.format, given.format_message)
    |> validate_unclaimed(given.identifier)
    |> put_token()
    |> put_expiry(opts)
    |> unique_constraint(:token_hash, Identifier.unique_opts(given.constraint))
  end

  # A query from a schema module, which is otherwise `Ithibati.Identity.*`'s job, and the exception
  # Ecto itself makes: `unsafe_validate_unique/4` takes a repo for exactly this shape of advisory
  # check. It cannot be moved to the context, because the answer has to be an error on the changeset
  # the form is rendering.
  #
  # What actually keeps two accounts off one address is the unique index on the accounts table,
  # which fires when the invitation is accepted. This is the earlier and kinder half of the same
  # answer: whoever is inviting is told at the form that this person already has an account, instead
  # of the invitee finding it out at the end of a passkey ceremony. Advisory by nature: an account
  # can be created between this query and the acceptance. That is why it does not replace the
  # index, and why it is worth having anyway.
  # Nothing is asked of the accounts table while the changeset is already invalid: a `phx-change`
  # form would otherwise send one `SELECT EXISTS` per keystroke, for values that cannot match an
  # account because they are not addresses yet.
  defp validate_unclaimed(%{valid?: false} = changeset, _field), do: changeset

  defp validate_unclaimed(changeset, field) do
    case get_change(changeset, field) do
      nil -> changeset
      identifier -> refuse_claimed(changeset, field, identifier)
    end
  end

  defp refuse_claimed(changeset, field, identifier) do
    schema = Config.user_schema()
    column = schema.__ithibati__(:identifier)
    taken? = Config.repo().exists?(from a in schema, where: field(a, ^column) == ^identifier)

    # `validation:` so that an application can tell this apart from a format error without
    # string-comparing the sentence, which is this library's wording and meant to be replaced.
    if taken?,
      do: add_error(changeset, field, "already has an account", validation: :unclaimed),
      else: changeset
  end

  # Nothing minted for a changeset that cannot be inserted: a `phx-change` form would otherwise put a
  # fresh plaintext secret into `changes` on every keystroke.
  #
  # Only on the way in. A changeset built to accept an invitation, or to correct a typo in the
  # address, must not quietly mint a second secret and strand the link that was already sent.
  defp put_token(%{valid?: false} = changeset), do: changeset

  defp put_token(%{data: %{token_hash: nil}} = changeset) do
    token = Secrets.token()

    changeset
    |> put_change(:token, token)
    |> put_change(:token_hash, Secrets.digest(token))
  end

  defp put_token(changeset), do: changeset

  # Passed, it always applies, so that an application can extend an invitation somebody has not got
  # round to; absent, it fills in the window only for one that has none yet. The token is unchanged
  # either way. Extending keeps the link that was already sent working, which is the point of it.
  defp put_expiry(changeset, opts) do
    case {Keyword.get(opts, :days), changeset.data.expires_at} do
      {nil, nil} -> expire_in(changeset, @default_days)
      {nil, _set} -> changeset
      {days, _} -> expire_in(changeset, days)
    end
  end

  defp expire_in(changeset, days) do
    put_change(changeset, :expires_at, DateTime.add(DateTime.utc_now(), days, :day))
  end

  @doc """
  Returns whether the module is loaded and exports the invitation-schema metadata function.

  This identifies the schema integration. `Ithibati.Config.invitation_schema/0` additionally
  checks agreement with the account identifier; migration and doctor checks inspect the table.
  """
  def invitation_schema?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__ithibati_invitation__, 1)
end
