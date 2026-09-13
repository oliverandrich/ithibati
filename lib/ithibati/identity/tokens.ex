defmodule Ithibati.Identity.Tokens do
  @moduledoc """
  Revocable credentials: what an account is issued once it has proved who it is.

  What `generate_token/2` returns is URL-safe text and the row holds only its sha256, so a database
  dump is not a set of live sessions. Every function takes the context the token belongs to, with
  `"session"` as a one-argument convenience beside it — a device token for an extension or a native
  app is then the same record with a different word in it. Decision 5 in `docs/design.md` says why.
  """

  import Ecto.Query

  alias Ithibati.Config
  alias Ithibati.Identity.Secrets
  alias Ithibati.UserToken

  @session "session"

  @bytes 32

  # The context the convenience functions promise, with the validity that goes with it — one module
  # owns both, so neither can be changed into a promise the other does not keep. An application may
  # still override it.
  @default_validity %{@session => {60, :day}}

  # `:month` and `:year` are missing on purpose: neither has a fixed length, and a validity that
  # moves with the calendar is not what anyone means by ninety days. The arithmetic itself is
  # `DateTime.shift/2`'s, not ours.
  @units [:second, :minute, :hour, :day, :week]

  ## The WebAuthn ceremony

  # WebAuthn Level 2, §5.1.3: a relying party must reject a credential id longer than 1023 bytes.
  # `Wax` does not — the length prefix is 16 bits, so an authenticator may claim up to 65535 — and
  # what arrives here is the browser's, which makes the size somebody else's choice.

  @doc """
  Mints a token for the account in this context and returns it as URL-safe text.

  What comes back is the only copy; what goes into the database is its digest.
  """
  def generate_token(account, context) when is_binary(context) do
    %{id: user_id} = Config.account!(account)
    known_context!(context)

    token = @bytes |> :crypto.strong_rand_bytes() |> Secrets.url64()

    Config.repo().insert!(
      UserToken.changeset(%UserToken{}, %{
        token_hash: Secrets.digest(token),
        context: context,
        user_id: user_id
      })
    )

    token
  end

  @doc """
  The account behind this token, or `nil`.

  `nil` covers every way there is not to have one: an unknown token, a revoked one, one older than
  its context allows, and `nil` itself — which is what a missing session key and a missing
  `authorization` header both give you, and making each call site write `token && …` around that
  only moves the omission somewhere less visible.
  """
  def get_user_by_token(token, context)
      when is_binary(context) and (is_binary(token) or is_nil(token)) do
    cutoff = cutoff(context)

    if token do
      from(t in UserToken,
        join: u in ^Config.user_schema(),
        on: u.id == t.user_id,
        where: t.token_hash == ^Secrets.digest(token),
        where: t.context == ^context,
        where: t.inserted_at > ^cutoff,
        select: u
      )
      |> Config.repo().one()
    end
  end

  @doc """
  Revokes a token. Revoking one that was never minted is not an error.

  Deliberately the one function that does not check the context against the configuration: the
  moment an application retires a context, revoking what it handed out is exactly what it needs,
  and refusing that would leave those rows reachable only by hand.
  """
  def delete_token(nil, context) when is_binary(context), do: :ok

  def delete_token(token, context) when is_binary(token) and is_binary(context) do
    from(t in UserToken, where: t.token_hash == ^Secrets.digest(token) and t.context == ^context)
    |> Config.repo().delete_all()

    :ok
  end

  @doc "Mints a session token — `generate_token/2` with the word this library fills in."
  def generate_session_token(account), do: generate_token(account, @session)

  @doc "The account behind a session token, or `nil`."
  def get_user_by_session_token(token), do: get_user_by_token(token, @session)

  @doc "Revokes a session token — a logout."
  def delete_session_token(token), do: delete_token(token, @session)

  defp cutoff(context) do
    {count, unit} = validity!(context)

    DateTime.shift(DateTime.utc_now(), [{unit, -count}])
  end

  # Called for its refusal rather than its answer: a context nobody configured would otherwise mint
  # a token that no lookup can accept, and it would do so silently.
  defp known_context!(context), do: validity!(context)

  # The whole setting is checked, not only the entry being asked for. Checking one entry would let
  # `%{"device" => {3, :month}}` boot, serve every session request, and first raise inside the
  # request that carries the first device token.
  defp validity!(context) do
    configured = Application.get_env(:ithibati, :token_validity, %{})

    # A keyword list is the idiom every other setting here uses, so it is what a reader reaches for;
    # atom keys are worse still, because they merge without complaint and the context is then
    # reported as unconfigured by someone who has just configured it.
    (is_map(configured) and Enum.all?(configured, fn {key, _} -> is_binary(key) end)) ||
      raise(
        ArgumentError,
        "config :ithibati, token_validity: — expected a map keyed by context strings, " <>
          ~s(as in %{"device" => {90, :day}}, got: ) <> inspect(configured)
      )

    validity = Map.merge(@default_validity, configured)

    Enum.each(validity, &valid_entry!/1)

    case Map.fetch(validity, context) do
      {:ok, entry} ->
        entry

      :error ->
        raise ArgumentError,
              "config :ithibati, token_validity: %{#{inspect(context)} => {90, :day}} — " <>
                "no validity is configured for that context, and there is no default to inherit"
    end
  end

  defp valid_entry!({_context, {count, unit}})
       when is_integer(count) and count > 0 and unit in @units,
       do: :ok

  defp valid_entry!({context, other}) do
    raise ArgumentError,
          "config :ithibati, token_validity: #{inspect(context)} => #{inspect(other)} — " <>
            "expected {count, unit} with a positive count and a unit in #{inspect(@units)}"
  end
end
