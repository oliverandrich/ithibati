defmodule Ithibati.Schema.Identifier do
  @moduledoc """
  Provides identifier normalization and built-in validation patterns.

  `normalize/1`, `username_format/0` and `email_format/0` are available to applications.
  The account and invitation macros use the same normalization and validation steps so their
  identifiers can be compared consistently.

  Other functions in this module support schema expansion and are internal to Ithibati.
  """

  import Ecto.Changeset

  # `nil`, `true` and `false` are atoms. A misspelled module attribute is `nil` with only a
  # warning, so `{@shape, :format}` compiles into `{nil, :format}` and fails at the first form.
  defguardp is_name(term) when is_atom(term) and term not in [nil, true, false]

  # RFC 5321's maximum for an address, and the longest identifier this library expects to see.
  @max 254

  # `\A`/`\z`, not `^`/`$`. Those match around a newline instead of at the ends of the
  # string, and `"you@example.com\n"` is a value this is asked about, because an application may call
  # this straight from its own `validate_format/3` with nothing trimmed first.
  @email_format ~r"\A[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\z"

  @doc """
  Returns the regex offered for email identifiers.

  The pattern accepts forms such as `you@example.com` and `you@localhost` and rejects quoted
  local parts such as `"a b"@example.com`. It checks syntax only; it does not verify ownership
  of a mailbox. Optional invitation delivery is separate from identifier validation.

  This deliberately narrow input format keeps identifiers easy to enter in browser forms.
  It does not implement the full RFC 5322 mailbox grammar; a rejected address is not
  necessarily an invalid mailbox.

  Pass it as `format:` to an account or invitation schema, or supply a pattern of your own.
  """
  def email_format, do: @email_format

  # Mastodon's rule for a *local* account, read out of `app/models/account.rb`: `[a-z0-9_]+`, at
  # most thirty characters. Its looser `USERNAME_RE`, which allows dots and hyphens, is for
  # addressing accounts on other servers, not for naming one's own.
  @username_format ~r/\A[a-z0-9_]{1,30}\z/

  @doc """
  Returns a regex accepting 1–30 lowercase ASCII letters, digits or underscores.

  The schema changesets normalize identifiers before applying this pattern. Direct callers
  should do the same if they want to accept mixed-case input. Dots, hyphens, spaces and
  non-ASCII characters are rejected. This limits punctuation variants and cross-script
  lookalikes, such as a Cyrillic letter resembling a Latin one. ASCII still contains
  lookalikes; the format does not guarantee that names cannot be confused.

  This format is optional. Supply your own `format:` when the application's identifier rules
  differ, and use a separate field for a display name.
  """
  def username_format, do: @username_format

  @doc "Trims and lowercases a string identifier; returns `nil` for `nil`."
  def normalize(nil), do: nil
  def normalize(value), do: value |> String.trim() |> String.downcase()

  @doc false
  def steps(struct_or_changeset, attrs, field, format, format_message) do
    struct_or_changeset
    |> cast(attrs, [field])
    |> update_change(field, &normalize/1)
    |> validate_required([field])
    |> validate_pattern(field, format, format_message)
    |> validate_length(field, max: @max)
  end

  @doc false
  def unique_opts(nil), do: []
  def unique_opts(name), do: [name: name]

  defp validate_pattern(changeset, field, format, message),
    do: applied(changeset, field, format_now(format), message_now(message))

  defp applied(changeset, _field, nil, _message), do: changeset

  defp applied(changeset, field, format, nil),
    do: validate_format(changeset, field, format)

  defp applied(changeset, field, format, message),
    do: validate_format(changeset, field, format, message: message)

  # Asked now rather than remembered, for the option given as a pair. What comes back is checked
  # here because a schema that compiled cleanly can still be pointed at a function that answers
  # with the wrong thing, and the first registration is the wrong place to find that out quietly.
  #
  # Whether the function exists at all is not checked anywhere earlier. It cannot be: the module
  # named here is usually compiled after the schema that names it, so asking at `use` time would
  # refuse a spelling that is right. A wrong one raises `UndefinedFunctionError` at the first
  # registration, which is why [Configuration](configuration.md) asks for a test that calls it.
  defp format_now({module, function}) do
    case apply(module, function, []) do
      %Regex{} = format -> format
      other -> refuse_answer!(module, function, :format, "a regular expression", other)
    end
  end

  defp format_now(given), do: given

  defp message_now({module, function}) do
    case apply(module, function, []) do
      message when is_binary(message) and message != "" -> message
      other -> refuse_answer!(module, function, :format_message, "a non-empty string", other)
    end
  end

  defp message_now(given), do: given

  defp refuse_answer!(module, function, key, expected, value) do
    raise ArgumentError,
          "`#{key}: {#{inspect(module)}, #{inspect(function)}}` must answer with #{expected}, " <>
            "got: #{inspect(value)}"
  end

  @doc false
  # A consumer's own clause for an injected function would win by clause order, and the library's
  # would never run.
  def refuse_shadowing!(env, generated, macro) do
    Enum.each(generated, fn {name, arity} ->
      Module.defines?(env.module, {name, arity}) &&
        raise(
          ArgumentError,
          "#{inspect(env.module)} defines #{name}/#{arity}, which use #{inspect(macro)} " <>
            "generates. Rename yours — a definition here silently replaces the library's."
        )
    end)
  end

  @doc false
  # `@ithibati_declared` is an ordinary attribute, so a line below the schema block can reassign it.
  # Holding it against the fields Ecto recorded is what makes the claim above true.
  def declared!(env, macro, entry) do
    field = Module.get_attribute(env.module, :ithibati_declared)

    field ||
      raise(
        ArgumentError,
        "#{inspect(env.module)} uses #{inspect(macro)} but never calls #{entry} inside its " <>
          "schema block, so it has no identifier field"
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

  @doc false
  # Told apart from "not given", because a non-literal reports the option as missing when it was in
  # fact passed. `true`/`false` are atoms, so a schema would compile with a field named `false`.
  def identifier!(opts, macro) do
    case Keyword.fetch(opts, :identifier) do
      {:ok, field} when is_atom(field) and field not in [nil, true, false] ->
        field

      {:ok, other} ->
        raise ArgumentError,
              "`identifier:` must be a literal atom, got: #{Macro.to_string(other)}. " <>
                "It is the field your schema declares, and this library wants it readable at the " <>
                "`use` line rather than named elsewhere. (The other options may be module " <>
                "attributes.)"

      :error ->
        raise ArgumentError,
              "use #{inspect(macro)} needs `identifier:` — the field somebody is known by, such " <>
                "as `identifier: :email` or `identifier: :username`. There is no default: this " <>
                "library does not assume that an account identifier is an email address."
    end
  end

  @doc false
  def options!(opts, macro) do
    is_list(opts) ||
      raise ArgumentError,
            "use #{inspect(macro)} takes a literal keyword list, got: #{Macro.to_string(opts)}"

    consistent!(opts)

    %{
      identifier: identifier!(opts, macro),
      format: deferred(opts, :format, :validated_format!),
      format_message: deferred(opts, :format_message, :validated_message!),
      constraint: deferred(opts, :constraint_name, :validated_constraint_name!),
      unique_index: deferred(opts, :unique_index, :validated_unique_index!, true)
    }
  end

  # A call, not a value, because `constraint_name: @index_name` is still an unresolved `@`
  # in the AST here: asking for its value where the macro expands is what the compiler refuses with
  # "undefined module attribute". The macro assigns the call to an attribute instead, and the
  # consumer's module body evaluates it. By then every attribute they wrote exists.
  #
  # Absence is decided here, where the key can still be seen, and that is the whole reason for
  # `default`. An option left out and an option written as `nil` are not the same thing: the second
  # is almost always a misspelled attribute, which evaluates to `nil` with nothing but a warning.
  # `unique_index:` is where that distinction has to be made and not merely kept. Absent means
  # `true`, and `true` is also a legal value, so absence cannot be represented by the checked call.
  defp deferred(opts, key, checker, default \\ nil) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> quote(do: unquote(__MODULE__).unquote(checker)(unquote(value)))
      :error -> default
    end
  end

  # The only cross-key question these options raise, so it is a statement of its own and the map
  # below stays a map. A sentence nobody ever reads is as silent as a pattern that checks nothing,
  # and this is the last point where both keys are still visible as keys.
  defp consistent!(opts) do
    if Keyword.has_key?(opts, :format_message) and not Keyword.has_key?(opts, :format) do
      raise ArgumentError,
            "`format_message:` needs a `format:` to word the refusal of. " <>
              "Nothing else here reports one."
    end
  end

  # Ecto takes any term and interpolates it into the error, so an atom would reach a form as
  # `:nope`. A binary is the only thing that reads like a sentence.
  # `""` is refused for the reason the whole option exists: it compiles, and it reaches the form as
  # a blank error beside the field.
  @doc false
  def validated_message!(message) when is_binary(message) and message != "", do: message

  def validated_message!({module, function} = asked) when is_name(module) and is_name(function),
    do: asked

  def validated_message!(other),
    do:
      refuse!(
        :format_message,
        other,
        "a non-empty string, or `{module, function}` answering with one"
      )

  # A format that is not a regular expression should say so where it is written, not at somebody's
  # first registration. A binary slips through `validate_format/4` as `String.contains?/2`, which
  # is wrong in both directions. It refuses `"abc"` against `"^[a-z]+$"` and accepts
  # `"x^[a-z]+$y"`.
  @doc false
  def validated_format!(%Regex{} = format), do: format

  # A pair rather than a capture, because the option is escaped into the generated changeset and
  # only a pair survives that unchanged. An instance whose identifier is a name in one deployment
  # and an address in another cannot answer when the schema compiles, so it names who to ask.
  def validated_format!({module, function} = asked) when is_name(module) and is_name(function),
    do: asked

  def validated_format!(other),
    do:
      refuse!(:format, other, "a regular expression, or `{module, function}` answering with one")

  # `true`/`false` are atoms too, and a constraint named "true" matches no index, so every duplicate
  # would surface as the `Ecto.ConstraintError` this option exists to prevent.
  @doc false
  def validated_constraint_name!(name) when is_name(name), do: name

  def validated_constraint_name!(other), do: refuse!(:constraint_name, other, "an atom")

  # Nothing else, and `nil` least of all: `Ithibati.Migration` branches on this value being truthy,
  # so a `nil` here is not a missing answer but a silent switch to checking for an index that
  # nobody is going to create.
  @doc false
  def validated_unique_index!(value) when is_boolean(value), do: value
  def validated_unique_index!(other), do: refuse!(:unique_index, other, "true or false")

  defp refuse!(key, value, expected) do
    raise ArgumentError,
          "`#{key}:` must be #{expected}, got: #{inspect(value)}" <> hint(key, value)
  end

  defp hint(:format, other) when is_binary(other), do: " — did you mean ~r/#{other}/?"

  defp hint(key, nil), do: attribute_hint("Leave `#{key}:` out to take the default.")
  defp hint(_key, {nil, _function}), do: attribute_hint("Spell the module the pair names.")
  defp hint(_key, {_module, nil}), do: attribute_hint("Spell the function the pair names.")
  defp hint(_key, _other), do: ""

  defp attribute_hint(advice),
    do: " — a misspelled module attribute is `nil` with only a warning. " <> advice
end
