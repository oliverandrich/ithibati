defmodule Ithibati.Schema.Identifier do
  @moduledoc """
  What an identifier is, for every schema Ithibati injects one into.

  An account is known by an identifier, through `Ithibati.Schema.User`. So is an invitation, which
  is addressed to one before the account exists, through `Ithibati.Schema.Invitation`. Both let
  the application name the field, and both hand the value through the same steps. That agreement
  matters: an invitation addressed to something an account could never be called is one nobody can
  accept. So the steps live here, once, and not in whichever macro was written first.

  Call `email_format/0`, `username_format/0` and `normalize/1` from an application. The rest is
  what the two macros use to read their own options.
  """

  import Ecto.Changeset

  # RFC 5321's maximum for an address, and the longest identifier this library expects to see.
  @max 254

  # `\A`/`\z`, not `^`/`$`. Those match around a newline instead of at the ends of the
  # string, and `"you@example.com\n"` is a value this is asked about, because an application may call
  # this straight from its own `validate_format/3` with nothing trimmed first.
  @email_format ~r"\A[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\z"

  @doc """
  The pattern to use when the identifier is an email address. Ithibati offers it instead of
  imposing it.

  It is the pattern the HTML specification publishes for `<input type=email>`, not RFC 5322. An
  identifier here is a credential, not a mailbox, so the full grammar's quoted local parts
  with spaces in them would be a hazard. The pattern accepts `you@localhost` and refuses
  `"a b"@example.com`.
  """
  def email_format, do: @email_format

  # Mastodon's rule for a *local* account, read out of `app/models/account.rb`: `[a-z0-9_]+`, at
  # most thirty characters. Its looser `USERNAME_RE`, which allows dots and hyphens, is for
  # addressing accounts on other servers, not for naming one's own.
  @username_format ~r/\A[a-z0-9_]{1,30}\z/

  @doc """
  The pattern to use when the identifier is a username. Ithibati offers it instead of imposing
  it.

  The pattern is borrowed, not invented: it is what Mastodon allows a local account, and
  that rule has survived a large number of people trying to impersonate each other. It allows
  letters, digits and underscores only, at most thirty characters.

  What it leaves out is the point. Dots and hyphens let `alice.smith` and `alice-smith` stand
  beside `alicesmith`, and anything beyond ASCII lets a Cyrillic `а` stand beside a Latin `a`.
  Each of those is a way to be told you are talking to someone you are not. A username is a
  credential here, and the display name people actually read is a separate field Ithibati knows
  nothing about.

  The pattern needs no case folding, because `normalize/1` has already lowercased the value. That
  is also why `Alice` and `alice` cannot become two accounts.
  """
  def username_format, do: @username_format

  @doc "An identifier as it is stored: trimmed and lowercased, whatever it is called."
  def normalize(nil), do: nil
  def normalize(value), do: value |> String.trim() |> String.downcase()

  @doc false
  def steps(struct_or_changeset, attrs, field, format) do
    struct_or_changeset
    |> cast(attrs, [field])
    |> update_change(field, &normalize/1)
    |> validate_required([field])
    |> validate_pattern(field, format)
    |> validate_length(field, max: @max)
  end

  @doc false
  def unique_opts(nil), do: []
  def unique_opts(name), do: [name: name]

  defp validate_pattern(changeset, _field, nil), do: changeset
  defp validate_pattern(changeset, field, format), do: validate_format(changeset, field, format)

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
                "library never sends mail, so it will not ask you for an address by assumption."
    end
  end

  @doc false
  def options!(opts, macro) do
    is_list(opts) ||
      raise ArgumentError,
            "use #{inspect(macro)} takes a literal keyword list, got: #{Macro.to_string(opts)}"

    %{
      identifier: identifier!(opts, macro),
      format: deferred(opts, :format, :validated_format!),
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

  # A format that is not a regular expression should say so where it is written, not at somebody's
  # first registration. A binary slips through `validate_format/4` as `String.contains?/2`, which
  # is wrong in both directions. It refuses `"abc"` against `"^[a-z]+$"` and accepts
  # `"x^[a-z]+$y"`.
  @doc false
  def validated_format!(%Regex{} = format), do: format
  def validated_format!(other), do: refuse!(:format, other, "a regular expression")

  # `true`/`false` are atoms too, and a constraint named "true" matches no index, so every duplicate
  # would surface as the `Ecto.ConstraintError` this option exists to prevent.
  @doc false
  def validated_constraint_name!(name) when is_atom(name) and name not in [nil, true, false],
    do: name

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

  defp hint(key, nil) do
    " — a misspelled module attribute is `nil` with only a warning. " <>
      "Leave `#{key}:` out to take the default."
  end

  defp hint(_key, _other), do: ""
end
