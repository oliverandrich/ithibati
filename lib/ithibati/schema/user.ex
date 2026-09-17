defmodule Ithibati.Schema.User do
  @moduledoc """
  Adds an identifier and credential associations to an application-owned account schema.

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

    * `:identifier` — required literal atom naming the account's identifier field.
    * `:format` — optional regex checked after normalization. See
      `Ithibati.Schema.Identifier.username_format/0` and `Ithibati.Schema.Identifier.email_format/0`.
    * `:format_message` — custom format-error message; requires `:format`.
      Defaults to Ecto's `"has invalid format"` message.
    * `:constraint_name` — optional identifier-index name. Used both when creating the index
      and when translating its constraint error into a changeset error.
    * `:unique_index` — defaults to `true`. Set `false` when the application creates the index;
      Ithibati still verifies that it guarantees uniqueness of the identifier column alone.

  Except for `:identifier`, values can be module attributes declared before `use`. Explicit
  `nil` values are rejected. See [Configuration and schemas](configuration.md) for examples.

  ## Generated fields and functions

  Call `ithibati_account/0` inside the schema block. It declares the identifier as `:string` and
  adds `:passkeys`, `:recovery_codes` and `:sessions` associations.

  The macro generates `identifier_changeset/2`, the overridable `passkey_display_name/1`, and
  `__ithibati__/1` for schema metadata. Identifier validation trims and lowercases the value,
  requires it, checks any supplied format and limits it to 254 graphemes.

  Compilation fails if the schema omits `ithibati_account/0` or defines its own
  `identifier_changeset/2` or `__ithibati__/1`. The application creates the database column;
  `Ithibati.Migration` creates or checks its unique index.
  """

  import Ecto.Changeset

  alias Ithibati.Identity.Concurrency
  alias Ithibati.Schema.Identifier

  @doc """
  Declares the identifier field and the associations Ithibati needs. Call it inside your
  `schema` block, in a module that has `use Ithibati.Schema.User` above it.
  """
  defmacro ithibati_account do
    quote do
      @ithibati_given ||
        raise(ArgumentError, "ithibati_account/0 needs `use Ithibati.Schema.User` above it")

      # The field and the generated functions both come from this one value, so they cannot name
      # different things.
      @ithibati_declared @ithibati_given.identifier

      field @ithibati_declared, :string

      has_many :passkeys, Ithibati.UserKey, foreign_key: :user_id
      has_many :recovery_codes, Ithibati.RecoveryCode, foreign_key: :user_id
      has_many :sessions, Ithibati.Session, foreign_key: :user_id
    end
  end

  defmacro __using__(opts) do
    given = Identifier.options!(opts, __MODULE__)

    quote do
      import Ithibati.Schema.User, only: [ithibati_account: 0]

      @before_compile Ithibati.Schema.User

      # Evaluate deferred checks here, where the consumer's module attributes exist.
      @ithibati_given unquote({:%{}, [], Map.to_list(given)})

      @doc """
      Returns the display name for passkey registration, or `nil` to use the identifier.

      Override this function when the application has a separate display field:

          def passkey_display_name(account), do: account.name

      A `nil` result falls back to the identifier in `Ithibati.Schema.User.credential_user/1`.
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
    given = env.module |> Module.get_attribute(:ithibati_given) |> Map.put(:identifier, field)

    quote do
      @doc """
      Returns metadata declared by `use Ithibati.Schema.User`.

        * `:identifier` — the identifier field name.
        * `:constraint` — the configured identifier-index name, or `nil` for Ecto's default name.
        * `:unique_index` — whether Ithibati should create that index.

      A named index can be managed by Ithibati or by the application; `:constraint` does not select
      which one manages it.
      """
      def __ithibati__(:identifier), do: unquote(field)
      def __ithibati__(:constraint), do: unquote(given.constraint)
      def __ithibati__(:unique_index), do: unquote(given.unique_index)

      @doc """
      Returns a changeset with the account identifier cast, normalized and validated.

      Accepts a struct or changeset and an attributes map. Validation requires the identifier,
      checks the configured regex when present, and limits it to 254 graphemes. The changeset
      also declares the identifier's unique constraint; the database enforces it on insert or update.

      Compose this into the application's changeset before validating additional fields.
      """
      def identifier_changeset(account_or_changeset, attrs) do
        # Written out because this is a quote: Elixir resolves aliases where the code is *written*,
        # so an alias here would be this module's and not the consumer's.
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        Ithibati.Schema.User.__changeset__(
          account_or_changeset,
          attrs,
          unquote(Macro.escape(given))
        )
      end
    end
  end

  @doc false
  def __changeset__(account_or_changeset, attrs, given) do
    account_or_changeset
    |> Identifier.steps(attrs, given.identifier, given.format, given.format_message)
    |> unique_constraint(given.identifier, Identifier.unique_opts(given.constraint))
  end

  @doc """
  Returns whether the module is loaded and exports the account-schema metadata function.

  Use this predicate instead of checking Ithibati's generated marker directly. It identifies
  the schema integration; it does not validate the database table or its indexes.
  """
  def account_schema?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__ithibati__, 1)

  @doc """
  Returns whether the changeset contains a unique-constraint error on the identifier field.

  Use this after a failed repo insert or update to distinguish an identifier collision from
  format errors or uniqueness errors on other application fields. The changeset must belong
  to a schema using `Ithibati.Schema.User`; otherwise this raises `ArgumentError`.

  A changeset that has not reached the database has no constraint error and returns `false`.
  The predicate checks the field's error metadata; it does not perform a uniqueness query or
  validate the index definition.
  """
  def identifier_taken?(%Ecto.Changeset{data: %module{}} = changeset) do
    ensure_account_schema!(module)

    Concurrency.collided?(changeset, module.__ithibati__(:identifier))
  end

  @doc """
  Returns `%{name: identifier, display_name: display_name}` for WebAuthn registration.

  For an account using `Ithibati.Schema.User`, the identifier comes from its declared field.
  The display name comes from `passkey_display_name/1`, falling back to the identifier when
  that function returns `nil` or `false`.

  For a string identifier, both values are that string. This function does not normalize it.
  An account struct without the schema integration raises `ArgumentError`.
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
