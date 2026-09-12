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

  `identifier:` is required and takes a literal atom — the field an account is known by. `format:` is
  optional and takes a regular expression, evaluated once when your module compiles. Whatever the
  field is called, values written through `identifier_changeset/2` are trimmed and lowercased.

  Why there is no default, and why the offered pattern is not RFC 5322, is in `docs/design.md`,
  decision 2.

  ## What it injects

  One field, three associations, and three functions: `identifier_changeset/2`,
  `passkey_display_name/1` (overridable, `nil` by default) and `__ithibati_identifier__/0`. The list
  is pinned in `Ithibati.Schema.UserTest` against a schema that does not use this macro, so a fourth
  one has to be a decision.
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

      field @ithibati_identifier, :string

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

    quote do
      import Ithibati.Schema.User, only: [ithibati_account: 0]

      @ithibati_identifier unquote(field)

      @doc "The field this account is known by."
      def __ithibati_identifier__, do: unquote(field)

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
          unquote(Macro.escape(format))
        )
      end

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

  @doc false
  def __changeset__(account_or_changeset, attrs, field, format) do
    account_or_changeset
    |> cast(attrs, [field])
    |> update_change(field, &normalize/1)
    |> validate_required([field])
    |> validate_pattern(field, format)
    |> validate_length(field, max: @max)
    |> unique_constraint(field)
  end

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
    function_exported?(module, :__ithibati_identifier__, 0) ||
      raise(ArgumentError, "#{inspect(module)} does not `use Ithibati.Schema.User`")

    identifier = Map.fetch!(account, module.__ithibati_identifier__())

    %{name: identifier, display_name: module.passkey_display_name(account) || identifier}
  end

  def credential_user(identifier) when is_binary(identifier),
    do: %{name: identifier, display_name: identifier}
end
