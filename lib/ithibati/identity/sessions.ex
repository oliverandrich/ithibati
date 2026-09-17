defmodule Ithibati.Identity.Sessions do
  @moduledoc """
  Issues, looks up and revokes server-side sessions.

  `generate_session_token/1` returns a plaintext token while storage keeps its SHA-256 digest.
  `get_user_by_session_token/1` returns the account only while that session remains valid.
  `delete_session_token/1` revokes one token.

  `Ithibati.Web.Gate` connects these calls to a browser session and LiveView sockets. Direct calls
  here do not update cookies or broadcast socket disconnections. API tokens with scopes or
  rotation are separate application concerns.
  """

  import Ecto.Query

  alias Ithibati.Config
  alias Ithibati.Identity.Secrets
  alias Ithibati.Session

  # Sixty days, and it is a module attribute and not a required setting because every
  # application has a session and almost none has an opinion about how long it lasts.
  @default_validity {60, :day}

  # `:month` and `:year` are missing on purpose: neither has a fixed length, and a validity that
  # moves with the calendar is not what anyone means by ninety days. The arithmetic itself is
  # `DateTime.shift/2`'s, not ours.
  @units [:second, :minute, :hour, :day, :week]

  @doc """
  Stores a new session and returns its plaintext, URL-safe token.

  The account must belong to the configured schema and exist in the database. The row stores
  only a digest, so retain the returned token for the client. Invalid session validity raises
  `ArgumentError`; an invalid insert raises `Ecto.InvalidChangesetError`.

  This call does not revoke other sessions or update a browser cookie.
  """
  def generate_session_token(account) do
    %{id: user_id} = Config.account!(account)

    # Called for its refusal, not its answer. A validity this library cannot read would
    # otherwise mint a session that every lookup afterwards raises on. Signing in would appear to
    # work and the request after it would not.
    configured_validity!()

    token = Secrets.token()

    Config.repo().insert!(
      Session.changeset(%Session{}, %{token_hash: Secrets.digest(token), user_id: user_id})
    )

    token
  end

  @doc """
  Returns the account for a valid session token, or `nil`.

  Unknown, revoked and expired tokens all return `nil`. A `nil` input also returns `nil` without
  reading configuration or querying the database.

  Validity is measured from session creation using `config :ithibati, session_validity:` and
  defaults to `{60, :day}`. Lookup does not extend a session. Invalid validity settings raise
  `ArgumentError` when looking up a string token.
  """
  # Two clauses, not one with a guard and an `if`. The `nil` path then provably reads no
  # configuration, so a page nobody is signed in to cannot answer 500 for a setting it never
  # needed. `delete_session_token/1` below is shaped the same way.
  def get_user_by_session_token(nil), do: nil

  def get_user_by_session_token(token) when is_binary(token) do
    cutoff = cutoff()

    from(s in Session,
      join: u in ^Config.user_schema(),
      on: u.id == s.user_id,
      where: s.token_hash == ^Secrets.digest(token),
      where: s.inserted_at > ^cutoff,
      select: u
    )
    |> Config.repo().one()
  end

  @doc "Revokes one token and returns `:ok`, including for `nil` or an unknown token."
  def delete_session_token(nil), do: :ok

  def delete_session_token(token) when is_binary(token) do
    from(s in Session, where: s.token_hash == ^Secrets.digest(token))
    |> Config.repo().delete_all()

    :ok
  end

  defp cutoff do
    {count, unit} = configured_validity!()

    DateTime.shift(DateTime.utc_now(), [{unit, -count}])
  end

  # Its own function because that is the question `Ithibati.Doctor` asks: is this setting readable.
  # It has to be able to ask that without minting or reading a session.
  @doc false
  def configured_validity! do
    validity!(Application.get_env(:ithibati, :session_validity, @default_validity))
  end

  # The check is the read, so there is no way to hold a validity that was not checked.
  defp validity!({count, unit} = validity)
       when is_integer(count) and count > 0 and unit in @units,
       do: validity

  defp validity!(other) do
    raise ArgumentError,
          "config :ithibati, session_validity: #{inspect(other)} — " <>
            "expected {count, unit} with a positive count and a unit in #{inspect(@units)}"
  end
end
