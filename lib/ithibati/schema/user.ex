defmodule Ithibati.Schema.User do
  @moduledoc """
  What an account owes this library, added to the schema an application already owns.

      defmodule MyApp.Accounts.User do
        use Ecto.Schema
        alias Ithibati.Schema.Identifier
        alias Ithibati.Schema.User

        use User, identifier: :email, format: Identifier.email_format()

        import Ecto.Changeset

        schema "users" do
          ithibati_account()

          field :name, :string
          timestamps(type: :utc_datetime_usec)
        end

        def changeset(user, attrs) do
          user
          |> identifier_changeset(attrs)
          |> cast(attrs, [:name])
        end
      end

  ## Options

    * `identifier:` — required, a literal atom: the field an account is known by. The one option
      that has to be written out here, because it is the field your schema declares.
    * `format:` — optional, a regular expression, evaluated once when your module compiles.
      `Ithibati.Schema.Identifier.email_format/0` offers one for addresses.
    * `constraint_name:` — optional, the name of the unique index on that column. Say it when your
      naming convention is not the one Ecto derives; this library then creates it under that name,
      and the changeset's constraint matches it.
    * `unique_index: false` — optional, an opt-out: say it when your application creates that index
      itself, and this library will check that one exists rather than create it.

  The three value options may each be written inline or named with a module attribute standing
  above the `use` line. An option written as `nil` is refused, because that is what a misspelled
  attribute looks like.

  Whatever the field is called, values written through `identifier_changeset/2` are trimmed and
  lowercased.

  Why there is no default, and why the offered pattern is not RFC 5322, is in `docs/design.md`,
  decision 2.

  ## What it injects, and what it refuses

  One field, three associations, and three functions: `identifier_changeset/2`,
  `passkey_display_name/1` (overridable, `nil` by default) and `__ithibati__/1`. The list
  is pinned in `Ithibati.Schema.UserTest` against a schema that does not use this macro, so a fourth
  one has to be a decision.

  Two things it refuses, both at compile time: a module that never calls `ithibati_account/0` inside
  its schema block, and one that defines `identifier_changeset/2` or `__ithibati__/1` itself.
  """

  import Ecto.Changeset

  alias Ithibati.Schema.Identifier

  @doc """
  Declares the identifier field and the associations this library needs. Call it inside your
  `schema` block, in a module that has `use Ithibati.Schema.User` above it.
  """
  defmacro ithibati_account do
    quote do
      @ithibati_identifier ||
        raise(ArgumentError, "ithibati_account/0 needs `use Ithibati.Schema.User` above it")

      # The field and the generated functions both come from this one value, so they cannot name
      # different things.
      @ithibati_declared @ithibati_identifier

      field @ithibati_declared, :string

      has_many :passkeys, Ithibati.UserKey, foreign_key: :user_id
      has_many :recovery_codes, Ithibati.RecoveryCode, foreign_key: :user_id
      has_many :auth_tokens, Ithibati.UserToken, foreign_key: :user_id
    end
  end

  defmacro __using__(opts) do
    given = Identifier.options!(opts, __MODULE__)

    quote do
      import Ithibati.Schema.User, only: [ithibati_account: 0]

      @before_compile Ithibati.Schema.User

      # Three of these may be a checking call rather than a value, so that an option written as
      # `@name` resolves here; see `Ithibati.Schema.Identifier.options!/2`.
      @ithibati_identifier unquote(given.identifier)
      @ithibati_format unquote(given.format)
      @ithibati_constraint unquote(given.constraint)
      @ithibati_unique_index unquote(given.unique_index)

      @doc """
      A name for this account that a passkey dialog can show, or `nil`.

      Returning `nil` is the ordinary answer, and this library then shows the identifier. Override it
      when the application has something better:

          def passkey_display_name(account), do: account.name

      No fallback is needed in an override — an account that has not filled the better name in
      returns `nil`, which is correct rather than broken.
      """
      def passkey_display_name(_account), do: nil

      defoverridable passkey_display_name: 1
    end
  end

  @doc false
  # The field has to come from what the schema block declared, which is only known once the module
  # body is done. `passkey_display_name/1` stays at `use` time instead: `defoverridable` needs the
  # original to exist before an override, and anything generated here comes after everything the
  # consumer wrote.
  defmacro __before_compile__(env) do
    Identifier.refuse_shadowing!(env, [__ithibati__: 1, identifier_changeset: 2], __MODULE__)

    field = Identifier.declared!(env, __MODULE__, "ithibati_account/0")
    format = Module.get_attribute(env.module, :ithibati_format)
    constraint = Module.get_attribute(env.module, :ithibati_constraint)
    unique_index = Module.get_attribute(env.module, :ithibati_unique_index)

    quote do
      @doc """
      What this library was told about this schema: `:identifier` is the field an account is known
      by, `:constraint` the unique index name the application said it maintains itself, or `nil`.
      """
      def __ithibati__(:identifier), do: unquote(field)
      def __ithibati__(:constraint), do: unquote(constraint)
      def __ithibati__(:unique_index), do: unquote(unique_index)

      @doc """
      Casts and validates the identifier, and declares the constraint this library relies on.

      Takes a struct or a changeset and returns a changeset, so you compose it into your own rather
      than being handed one that owns the account.
      """
      def identifier_changeset(account_or_changeset, attrs) do
        # Written out because this is a quote: Elixir resolves aliases where the code is *written*,
        # so an alias here would be this module's and not the consumer's.
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        Ithibati.Schema.User.__changeset__(
          account_or_changeset,
          attrs,
          unquote(field),
          unquote(Macro.escape(format)),
          unquote(Macro.escape(constraint))
        )
      end
    end
  end

  @doc false
  def __changeset__(account_or_changeset, attrs, field, format, constraint) do
    account_or_changeset
    |> Identifier.steps(attrs, field, format)
    |> unique_constraint(field, Identifier.unique_opts(constraint))
  end

  @doc """
  Whether a module carries what this macro injects.

  One predicate rather than two spellings of it: the marker function has been renamed once already,
  and a second caller checking it by hand is a second thing to find by grep next time.
  """
  def account_schema?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__ithibati__, 1)

  @doc """
  Whether the identifier is what a failed insert collided on.

  A transaction that refuses an account hands back an `Ecto.Changeset`, and an application then has
  to decide what to tell somebody. "That name is taken" and "that is not a name" come from
  different places — a unique index and the format — and only this library knows which *field* is
  the identifier, because `ithibati_account/0` is what declared it.

  The field is what is matched, so a uniqueness error on it counts however the index is shaped: an
  application that scopes the identifier to a tenant gets `true` for a collision inside that
  tenant, which is what it means there.

  Answered rather than said: whether this becomes `:username_taken`, an English sentence or an HTTP
  status stays with the application, the same way `Ithibati.Web.Handler` leaves what a verified
  assertion is worth to the application. A library that shipped the wording would be choosing the
  tone of somebody else's product.

  > #### Only after the database has seen it {: .warning}
  >
  > A constraint error exists on a changeset only once an insert has been attempted and refused. A
  > changeset built and never given to the repo answers `false` however certainly the name is
  > taken, which looks exactly like this function not working.

  """
  def identifier_taken?(%Ecto.Changeset{data: %module{}} = changeset) do
    ensure_account_schema!(module)

    changeset.errors
    |> Keyword.get_values(module.__ithibati__(:identifier))
    |> Enum.any?(fn {_message, opts} -> opts[:constraint] == :unique end)
  end

  @doc """
  The `name` and `displayName` a WebAuthn registration shows, for an account or for an identifier
  that does not have one yet.

  Both are derived here rather than by the caller, because the fallback is this library's to own: a
  consumer's `passkey_display_name/1` may answer `nil` and be right. The first registration on an
  instance has no account at all, which is why the second clause exists.
  """
  def credential_user(%module{} = account) do
    ensure_account_schema!(module)

    identifier = Map.fetch!(account, module.__ithibati__(:identifier))

    %{name: identifier, display_name: module.passkey_display_name(account) || identifier}
  end

  def credential_user(identifier) when is_binary(identifier),
    do: %{name: identifier, display_name: identifier}

  # One reaction to `account_schema?/1`, for the same reason there is one predicate: a message
  # spelled twice is a message that gets edited once.
  defp ensure_account_schema!(module) do
    account_schema?(module) ||
      raise(ArgumentError, "#{inspect(module)} does not `use Ithibati.Schema.User`")
  end
end
