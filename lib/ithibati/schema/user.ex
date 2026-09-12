defmodule Ithibati.Schema.User do
  @moduledoc """
  What an account owes this library, added to the schema an application already owns.

      defmodule MyApp.Accounts.User do
        use Ecto.Schema
        alias Ithibati.Schema.User

        use User, identifier: :email, format: User.email_format()

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

    * `identifier:` — required, a literal atom: the field an account is known by.
    * `format:` — optional, a regular expression, evaluated once when your module compiles.
    * `constraint_name:` — optional, and an opt-out: say it when your application maintains the
      unique index on that column itself, and this library will not create one. Name it, because
      the constraint still has to match.

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

  # RFC 5321's maximum for an address, and the longest identifier this library expects to see.
  @max 254

  @email_format ~r"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$"

  @doc """
  The pattern to use when the identifier is an email address — offered, not imposed.

  It is the one the HTML specification publishes for `<input type=email>` rather than RFC 5322: an
  identifier here is a credential, not a mailbox, so the full grammar's quoted local parts with
  spaces in them would be a hazard. It accepts `you@localhost`; it refuses `"a b"@example.com`.
  """
  def email_format, do: @email_format

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
    is_list(opts) ||
      raise(
        ArgumentError,
        "use Ithibati.Schema.User takes a literal keyword list, got: #{Macro.to_string(opts)}"
      )

    field = identifier!(opts)
    format = format!(opts, __CALLER__)
    constraint = constraint_name!(opts)

    quote do
      import Ithibati.Schema.User, only: [ithibati_account: 0]

      @before_compile Ithibati.Schema.User

      @ithibati_identifier unquote(field)
      @ithibati_format unquote(Macro.escape(format))
      @ithibati_constraint unquote(Macro.escape(constraint))

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
    refuse_shadowing!(env)

    field = declared!(env)
    format = Module.get_attribute(env.module, :ithibati_format)
    constraint = Module.get_attribute(env.module, :ithibati_constraint)

    quote do
      @doc """
      What this library was told about this schema: `:identifier` is the field an account is known
      by, `:constraint` the unique index name the application said it maintains itself, or `nil`.
      """
      def __ithibati__(:identifier), do: unquote(field)
      def __ithibati__(:constraint), do: unquote(constraint)

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

  # A consumer's own clause for `__ithibati__(:identifier)` would win by clause order, and the
  # library's would never run.
  defp refuse_shadowing!(env) do
    Enum.each([__ithibati__: 1, identifier_changeset: 2], fn {name, arity} ->
      Module.defines?(env.module, {name, arity}) &&
        raise(
          ArgumentError,
          "#{inspect(env.module)} defines #{name}/#{arity}, which use Ithibati.Schema.User " <>
            "generates. Rename yours — a definition here silently replaces the library's."
        )
    end)
  end

  # `@ithibati_declared` is an ordinary attribute, so a line below the schema block can reassign it.
  # Holding it against the fields Ecto recorded is what makes the claim above true.
  defp declared!(env) do
    field = Module.get_attribute(env.module, :ithibati_declared)

    field ||
      raise(
        ArgumentError,
        "#{inspect(env.module)} uses Ithibati.Schema.User but never calls ithibati_account/0 " <>
          "inside its schema block, so it has no identifier field"
      )

    declared = env.module |> Module.get_attribute(:ecto_fields) |> Keyword.keys()

    field in declared ||
      raise(
        ArgumentError,
        "#{inspect(env.module)} has no field #{inspect(field)}; its schema declares " <>
          "#{inspect(declared)}. Something reassigned @ithibati_declared after the schema block."
      )

    field
  end

  # Told apart from "not given", because a non-literal reports the option as missing when it was in
  # fact passed — and `true`/`false` are atoms, so a schema would compile with a field named `false`.
  defp identifier!(opts) do
    case Keyword.fetch(opts, :identifier) do
      {:ok, field} when is_atom(field) and field not in [nil, true, false] ->
        field

      {:ok, other} ->
        raise ArgumentError,
              "`identifier:` must be a literal atom, got: #{Macro.to_string(other)}. " <>
                "The macro reads it while your module compiles, so a variable or attribute " <>
                "cannot be seen here."

      :error ->
        raise ArgumentError,
              "use Ithibati.Schema.User needs `identifier:` — the field an account is known by, " <>
                "such as `identifier: :email` or `identifier: :username`. There is no default: " <>
                "this library never sends mail, so it will not ask you for an address by assumption."
    end
  end

  # Evaluated here rather than in the generated function body, for two reasons that are the same
  # reason: it happens once instead of per changeset, and what comes out can be checked. A binary
  # slips through `validate_format/4` as `String.contains?/2`, which is wrong in both directions —
  # it would refuse `"abc"` against `"^[a-z]+$"` and accept `"x^[a-z]+$y"`.
  defp format!(opts, env) do
    case Keyword.fetch(opts, :format) do
      :error ->
        nil

      {:ok, ast} ->
        {value, _binding} = Code.eval_quoted(ast, [], env)

        is_struct(value, Regex) ||
          raise(
            ArgumentError,
            "`format:` must be a regular expression, got: #{inspect(value)}" <>
              if(is_binary(value), do: " — did you mean ~r/#{value}/?", else: "")
          )

        value
    end
  end

  # The bare name, because two callers want different things from it: the changeset needs an option
  # list, and the migration needs to know whether one was given at all.
  defp constraint_name!(opts) do
    case Keyword.fetch(opts, :constraint_name) do
      :error ->
        nil

      # `true`/`false` are atoms too, and a constraint named "true" matches no index — every
      # duplicate would then surface as the `Ecto.ConstraintError` this option exists to prevent.
      {:ok, name} when is_atom(name) and name not in [nil, true, false] ->
        name

      {:ok, other} ->
        raise ArgumentError, "`constraint_name:` must be an atom, got: #{Macro.to_string(other)}"
    end
  end

  @doc false
  def __changeset__(account_or_changeset, attrs, field, format, constraint) do
    account_or_changeset
    |> cast(attrs, [field])
    |> update_change(field, &normalize/1)
    |> validate_required([field])
    |> validate_pattern(field, format)
    |> validate_length(field, max: @max)
    |> unique_constraint(field, unique_opts(constraint))
  end

  defp unique_opts(nil), do: []
  defp unique_opts(name), do: [name: name]

  defp validate_pattern(changeset, _field, nil), do: changeset
  defp validate_pattern(changeset, field, format), do: validate_format(changeset, field, format)

  @doc "An identifier as it is stored: trimmed and lowercased, whatever it is called."
  def normalize(nil), do: nil
  def normalize(value), do: value |> String.trim() |> String.downcase()

  @doc """
  The `name` and `displayName` a WebAuthn registration shows, for an account or for an identifier
  that does not have one yet.

  Both are derived here rather than by the caller, because the fallback is this library's to own: a
  consumer's `passkey_display_name/1` may answer `nil` and be right. The first registration on an
  instance has no account at all, which is why the second clause exists.
  """
  def credential_user(%module{} = account) do
    function_exported?(module, :__ithibati__, 1) ||
      raise(ArgumentError, "#{inspect(module)} does not `use Ithibati.Schema.User`")

    identifier = Map.fetch!(account, module.__ithibati__(:identifier))

    %{name: identifier, display_name: module.passkey_display_name(account) || identifier}
  end

  def credential_user(identifier) when is_binary(identifier),
    do: %{name: identifier, display_name: identifier}
end
