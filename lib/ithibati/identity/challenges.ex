defmodule Ithibati.Identity.Challenges do
  @moduledoc """
  Tracks outstanding challenges in the configured database across application instances.

  The transport retains the challenge and its approved subject and policy. This module stores
  only a digest and expiry. Consume the record before verification, outside any transaction
  that could roll back after a handler fails. Database errors propagate; they never authorize
  verification. Applications may schedule `delete_expired/0` to remove abandoned challenges.
  """
  import Ecto.Query

  alias Ithibati.Challenge
  alias Ithibati.Config
  alias Ithibati.Identity.Secrets

  @doc "Records a newly issued challenge until its timeout expires. Returns `:ok`."
  def store(%Wax.Challenge{bytes: bytes, timeout: seconds}) do
    Config.repo().insert!(%Challenge{
      token_hash: Secrets.digest(bytes),
      expires_at: DateTime.add(DateTime.utc_now(), seconds, :second)
    })

    :ok
  end

  @doc """
  Atomically consumes an unexpired challenge, returning `:ok` or `{:error, :no_challenge}`.

  Raises `ArgumentError` inside a transaction: a later rollback must not restore consumption.
  """
  def consume(%Wax.Challenge{bytes: bytes}) do
    Config.repo().in_transaction?() &&
      raise ArgumentError, "consume a challenge outside an application transaction"

    {count, _} =
      Config.repo().delete_all(
        from(c in Challenge,
          where: c.token_hash == ^Secrets.digest(bytes) and c.expires_at > ^DateTime.utc_now()
        )
      )

    if count == 1, do: :ok, else: {:error, :no_challenge}
  end

  @doc "Deletes abandoned, expired challenge records and returns the number removed."
  def delete_expired do
    {count, _} =
      Config.repo().delete_all(from(c in Challenge, where: c.expires_at <= ^DateTime.utc_now()))

    count
  end
end
