defmodule Ithibati.Schema.Invitation do
  @moduledoc """
  What Ithibati puts on an invitation, and what an invitation owes Ithibati.

  The table belongs to the application, like the accounts table and for the same reason. An
  invitation says what somebody is being invited *to*, such as a role, a site or a team, and
  that is exactly what this library keeps out of itself. So you declare the schema in your
  application, and
  this macro adds Ithibati's half of it:

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

  The options are the account macro's. `identifier:` is required, and it is the one you have to
  write out. `format:` takes a regular expression, and `Ithibati.Schema.Identifier.email_format/0`
  offers a pattern for addresses. `constraint_name:` and `unique_index:` name the unique index on
  the token digest and not on the identifier. `format_message:` words the refusal a `format:`
  reports. You may write each of the four value options inline, or name a module attribute
  standing above the `use` line.

  `identifier:` names the field the invitee is addressed by. It has to be the same field the
  account schema uses, and `Ithibati.Config.invitation_schema/0` refuses the pair when it is not.
  Ithibati cannot read the field from the account schema instead, because a schema's fields are
  fixed when the module compiles, and which schema is the account's is read at runtime.
  """

  import Ecto.Changeset
  import Ecto.Query

  @default_days 7

  alias Ithibati.Config
  alias Ithibati.Identity.Secrets
  alias Ithibati.Schema.Identifier

  @doc """
  Declares the fields Ithibati owns, inside the schema block.

  Four columns and one virtual field. The columns are the invitee's identifier, the token's
  digest, when the invitation stops being acceptable, and when it was accepted. The virtual field
  is `:token`, which is not stored. Ithibati puts the plaintext there when the invitation is
  built, and that is the only copy there will ever be.
  """
  defmacro ithibati_invitation do
    quote do
      @ithibati_identifier ||
        raise(
          ArgumentError,
          "ithibati_invitation/0 needs `use Ithibati.Schema.Invitation` above it"
        )

      @ithibati_declared @ithibati_identifier

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

      # Four of these may be a checking call instead of a value, so that an option written as
      # `@name` resolves here; see `Ithibati.Schema.Identifier.options!/2`.
      @ithibati_identifier unquote(given.identifier)
      @ithibati_format unquote(given.format)
      @ithibati_format_message unquote(given.format_message)
      @ithibati_constraint unquote(given.constraint)
      @ithibati_unique_index unquote(given.unique_index)
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
    format = Module.get_attribute(env.module, :ithibati_format)
    format_message = Module.get_attribute(env.module, :ithibati_format_message)
    constraint = Module.get_attribute(env.module, :ithibati_constraint)
    unique_index = Module.get_attribute(env.module, :ithibati_unique_index)

    quote do
      @doc """
      What Ithibati was told about this schema. `:identifier` is the field an invitee is addressed
      by. `:constraint` is the unique index name on the token digest that the application said it
      maintains itself, or `nil`.
      """
      def __ithibati_invitation__(:identifier), do: unquote(field)
      def __ithibati_invitation__(:constraint), do: unquote(constraint)
      def __ithibati_invitation__(:unique_index), do: unquote(unique_index)

      @doc """
      Casts the invitee's identifier, mints the token and sets the expiry.

      It takes a struct or a changeset and answers a changeset, so you compose it into your own.
      `days:` says how long the invitation stays acceptable. It defaults to seven for a new
      invitation, and passing it to an existing one moves the expiry, which is how you extend an
      invitation. Ithibati never mints the token twice, so the link that was already sent still
      opens an extended invitation.
      """
      def invitation_changeset(invitation_or_changeset, attrs, opts \\ []) do
        # Written out because this is a quote: Elixir resolves aliases where the code is *written*,
        # so an alias here would be this module's and not the consumer's.
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        Ithibati.Schema.Invitation.__changeset__(
          invitation_or_changeset,
          attrs,
          opts,
          unquote(field),
          unquote(Macro.escape(format)),
          unquote(format_message),
          unquote(Macro.escape(constraint))
        )
      end
    end
  end

  @doc false
  def __changeset__(
        invitation_or_changeset,
        attrs,
        opts,
        field,
        format,
        format_message,
        constraint
      ) do
    invitation_or_changeset
    |> Identifier.steps(attrs, field, format, format_message)
    |> validate_unclaimed(field)
    |> put_token()
    |> put_expiry(opts)
    |> unique_constraint(:token_hash, Identifier.unique_opts(constraint))
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
  Whether a module carries what this macro injects.

  This is the invitation half of `Ithibati.Schema.User.account_schema?/1`, and it is public for
  the same reason. An application that configures an invitation schema can ask whether the module
  is one, instead of checking for the marker function by hand and finding out the next time it
  is renamed.
  """
  def invitation_schema?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__ithibati_invitation__, 1)
end
