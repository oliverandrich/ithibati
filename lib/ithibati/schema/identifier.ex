defmodule Ithibati.Schema.Identifier do
  @moduledoc """
  What an identifier is, for every schema this library injects one into.

  An account is known by one — `Ithibati.Schema.User` — and so is an invitation, which is addressed
  to one before the account exists — `Ithibati.Schema.Invitation`. Both let the application name the
  field and both hand the value through the same steps, and that agreement is not decoration: an
  invitation addressed to something an account could never be called is one nobody can accept. So
  the steps live here, once, rather than in whichever macro was written first.

  Only `email_format/0`, `username_format/0` and `normalize/1` are meant to be called from an
  application; the rest is what the two macros use to read their own options.
  """

  import Ecto.Changeset

  # RFC 5321's maximum for an address, and the longest identifier this library expects to see.
  @max 254

  # `\A`/`\z` rather than `^`/`$`, which match around a newline rather than at the ends of the
  # string: `"you@example.com\n"` is a value this is asked about, because an application may call
  # this straight from its own `validate_format/3` with nothing trimmed first.
  @email_format ~r"\A[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\z"

  @doc """
  The pattern to use when the identifier is an email address — offered, not imposed.

  It is the one the HTML specification publishes for `<input type=email>` rather than RFC 5322: an
  identifier here is a credential, not a mailbox, so the full grammar's quoted local parts with
  spaces in them would be a hazard. It accepts `you@localhost`; it refuses `"a b"@example.com`.
  """
  def email_format, do: @email_format

  # Mastodon's rule for a *local* account, read out of `app/models/account.rb`: `[a-z0-9_]+`, at
  # most thirty characters. Its looser `USERNAME_RE`, which allows dots and hyphens, is for
  # addressing accounts on other servers, not for naming one's own.
  @username_format ~r/\A[a-z0-9_]{1,30}\z/

  @doc """
  The pattern to use when the identifier is a username — offered, not imposed.

  Borrowed rather than invented: it is what Mastodon allows a local account, which is a rule that
  has survived a large number of people trying to impersonate each other. Letters, digits and
  underscores only, at most thirty characters.

  What it leaves out is the point. Dots and hyphens let `alice.smith` and `alice-smith` stand
  beside `alicesmith`, and anything beyond ASCII lets a Cyrillic `а` stand beside a Latin `a` —
  three ways to be told you are talking to someone you are not. A username is a credential here,
  and the display name people actually read is a separate field this library knows nothing about.

  No case folding is needed in the pattern: `normalize/1` has already lowercased the value, which
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
  # fact passed — and `true`/`false` are atoms, so a schema would compile with a field named `false`.
  def identifier!(opts, macro) do
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
              "use #{inspect(macro)} needs `identifier:` — the field somebody is known by, such " <>
                "as `identifier: :email` or `identifier: :username`. There is no default: this " <>
                "library never sends mail, so it will not ask you for an address by assumption."
    end
  end

  # Evaluated here rather than in the generated function body, for two reasons that are the same
  # reason: it happens once instead of per changeset, and what comes out can be checked. A binary
  # slips through `validate_format/4` as `String.contains?/2`, which is wrong in both directions —
  # it would refuse `"abc"` against `"^[a-z]+$"` and accept `"x^[a-z]+$y"`.
  @doc false
  def format!(opts, env) do
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

  # The bare name: the changeset turns it into an option list, and the migration names the index it
  # creates.
  @doc false
  def constraint_name!(opts) do
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
  def unique_index!(opts) do
    case Keyword.fetch(opts, :unique_index) do
      :error ->
        true

      {:ok, value} when is_boolean(value) ->
        value

      {:ok, other} ->
        raise ArgumentError,
              "`unique_index:` must be true or false, got: #{Macro.to_string(other)}"
    end
  end
end
