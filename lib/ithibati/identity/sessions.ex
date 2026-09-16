defmodule Ithibati.Identity.Sessions do
  @moduledoc """
  The revocable half of being signed in: what an account is issued once it has proved who it is.

  `generate_session_token/1` returns URL-safe text, and the row holds only its sha256, so a
  database dump is not a set of live sessions. `Ithibati.Web.Gate` is what calls all three
  functions; an application reaches them through it, not directly.

  A session is the only credential this table holds. An API token for an extension or a native
  client is a different thing — scopes, rotation, a page to revoke one on — and building it is
  the application's, or another library's.
  """

  import Ecto.Query

  alias Ithibati.Config
  alias Ithibati.Identity.Secrets
  alias Ithibati.Session

  # Sixty days, and it is a module attribute rather than a required setting because every
  # application has a session and almost none has an opinion about how long it lasts.
  @default_validity {60, :day}

  # `:month` and `:year` are missing on purpose: neither has a fixed length, and a validity that
  # moves with the calendar is not what anyone means by ninety days. The arithmetic itself is
  # `DateTime.shift/2`'s, not ours.
  @units [:second, :minute, :hour, :day, :week]

  @doc """
  Mints a session token for the account and returns it as URL-safe text.

  What comes back is the only copy. The database gets its digest.
  """
  def generate_session_token(account) do
    %{id: user_id} = Config.account!(account)

    # Called for its refusal rather than its answer: a validity this library cannot read would
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
  The account behind this session token, or `nil`.

  `nil` covers every way there is not to have a valid session: an unknown token, a revoked one,
  one older than the configured validity, and `nil` itself. A missing session key gives you
  `nil`, and making each call site write `token && …` around that only moves the omission
  somewhere less visible.
  """
  # Two clauses rather than one with a guard and an `if`: the `nil` path then provably reads no
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

  @doc "Revokes a session token: a logout. Revoking one that was never minted is not an error."
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

  # Its own function because that is the question `Ithibati.Doctor` asks — is this setting
  # readable — which it has to be able to ask without minting or reading a session.
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
