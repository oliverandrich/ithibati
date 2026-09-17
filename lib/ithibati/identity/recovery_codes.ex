defmodule Ithibati.Identity.RecoveryCodes do
  @moduledoc """
  Issues and redeems single-use recovery codes for accounts without an available passkey.

  A batch contains twelve codes by default. Issuance returns plaintext codes while storage keeps
  only their SHA-256 digests. The application must display or deliver the plaintext at issuance.

  Spending the last unused code refills the batch by default. Redemption returns the account and
  any fresh codes; the caller decides whether to issue a session.
  """

  import Ecto.Query

  alias Ithibati.Config
  alias Ithibati.Identity.Concurrency
  alias Ithibati.Identity.Secrets
  alias Ithibati.RecoveryCode

  # Ten random bytes produce sixteen lowercase base32 characters (80 bits).
  # The built-in encoder uses the RFC 4648 alphabet, including visually similar letters.
  @count 12
  @bytes 10

  @doc "How many unused codes this account has left."
  def remaining(account) do
    account = Config.account!(account)

    Config.repo().aggregate(unused(account), :count)
  end

  @doc """
  Returns a fresh list of plaintext codes and invalidates all previous codes for the account.

  The `:count` option defaults to `12` and accepts a non-negative integer. `count: 0` invalidates
  the previous batch without issuing replacements. Other values raise `ArgumentError`.

  The account must belong to the configured schema and exist in the database. Replacement is
  transactional and serialized with other regeneration and redemption calls for that account.

  Only digests are stored. Display or deliver the returned codes now; they cannot be retrieved
  from the database later.
  """
  def regenerate(account, opts \\ []) do
    account = Config.account!(account)

    {:ok, codes} =
      Concurrency.transaction(Config.repo(), fn ->
        # Serialize regeneration with redemption and other regenerations. Without the account lock,
        # concurrent replacements can each miss the other batch and leave both active.
        Concurrency.lock_account!(account.id)
        replace(account, opts)
      end)

    codes
  end

  @doc """
  Spends a recovery code and returns `{:ok, account, fresh_codes}` or `{:error, :invalid}`.

  `fresh_codes` is `nil` while unused codes remain. When the last one is spent, the same
  transaction issues a replacement batch and returns its plaintext list. Preserve that list
  for display; it cannot be recovered from the stored digests.

  ## Options

    * `:refill` — defaults to `true`; pass `false` to disable replacement.
    * `:count` — size of a replacement batch, default `12`. Accepts a non-negative integer;
      invalid values raise when a replacement batch is needed.

  Unknown and already-spent codes both return `{:error, :invalid}`. A `nil` input returns the
  same error; other non-string inputs do not match the function's clauses.

  Redemption does not create a session. Concurrent redemption and regeneration are serialized
  on the account row so spending and refilling use a consistent ordering.
  """
  def redeem(code, opts \\ [])

  def redeem(code, opts) when is_binary(code) do
    digest = Secrets.digest(code)
    repo = Config.repo()

    Concurrency.transaction(repo, fn ->
      # Lock the account before updating a code. Regeneration takes locks in that order too;
      # reversing it here would allow the two operations to deadlock.
      with account when account != nil <- lock_owner(digest),
           {:ok, _spent} <- spend(digest) do
        {account, refill(account, opts)}
      else
        _absent_or_spent -> repo.rollback(:invalid)
      end
    end)
    |> case do
      {:ok, {account, codes}} -> {:ok, account, codes}
      {:error, reason} -> {:error, reason}
    end
  end

  # Missing form values are invalid codes. Other non-string inputs remain caller errors.
  def redeem(nil, _opts), do: {:error, :invalid}

  # Keep the unused predicate in the update so concurrent attempts cannot both spend one code.
  defp spend(digest) do
    query =
      from(r in RecoveryCode, where: r.code_hash == ^digest and is_nil(r.used_at), select: r)

    Config.repo().update_all(query, set: [used_at: DateTime.utc_now()])
    |> Concurrency.one_affected(:invalid)
  end

  # The account lock serializes spending different code rows. Count after acquiring it so
  # the final redemption observes previous spends and performs the refill.
  defp refill(account, opts) do
    if Keyword.get(opts, :refill, true) and remaining(account) == 0,
      do: replace(account, opts)
  end

  @doc false
  # The grant passes its transaction repo while provisioning an account. It needs no extra
  # lock because that account is not yet available to concurrent redemption.
  # Bulk insertion avoids a database round trip per code; IDs and timestamps are supplied here.
  def issue!(repo, account, opts \\ []) do
    account = Config.account!(account)
    now = DateTime.utc_now()

    # `1..0` counts *down*, so without the step a count of zero issues two codes nobody was shown.
    codes = for _ <- 1..count(opts)//1, do: code()

    repo.delete_all(from r in RecoveryCode, where: r.user_id == ^account.id)

    repo.insert_all(
      RecoveryCode,
      Enum.map(codes, fn code ->
        %{user_id: account.id, code_hash: Secrets.digest(code), inserted_at: now, updated_at: now}
      end)
    )

    codes
  end

  defp replace(account, opts), do: issue!(Config.repo(), account, opts)

  # The subquery finds the account without locking the code row, preserving the account-first
  # lock order shared with regeneration.
  defp lock_owner(digest) do
    owner = from(r in RecoveryCode, where: r.code_hash == ^digest, select: r.user_id)

    Config.user_schema()
    |> where([account], account.id in subquery(owner))
    |> Concurrency.lock_rows()
    |> Config.repo().one()
  end

  defp unused(account) do
    from r in RecoveryCode, where: r.user_id == ^account.id and is_nil(r.used_at)
  end

  defp count(opts) do
    case Keyword.get(opts, :count, @count) do
      count when is_integer(count) and count >= 0 -> count
      other -> raise ArgumentError, "count: must be a non-negative integer, got #{inspect(other)}"
    end
  end

  defp code,
    do:
      @bytes |> :crypto.strong_rand_bytes() |> Base.encode32(padding: false) |> String.downcase()
end
