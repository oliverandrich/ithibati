defmodule Ithibati.Identity.RecoveryCodes do
  @moduledoc """
  Single-use codes, for the day a passkey is gone.

  A passkey-only account has one credential set, and one lost keychain would otherwise be the end of
  it. These are the second set: twelve codes by default, shown once, each good for exactly one
  sign-in. How many, and whether spending the last one brings a fresh batch, are the application's
  to set — `docs/design.md` decision 8.
  """

  import Ecto.Query

  alias Ithibati.Config
  alias Ithibati.Identity.Secrets
  alias Ithibati.RecoveryCode

  # Twelve is what fits a printed sheet, and eighty bits each is more than a guess can reach.
  # Sixteen lowercase base32 characters: one case, one alphabet, no separators. RFC 4648 keeps `i`,
  # `l`, `o` and `b`, so it is not the variant that removes the confusable glyphs — it is the one
  # Elixir ships, and hand-rolling Crockford to gain four letters is not a trade this library makes.
  @count 12
  @bytes 10

  @doc "How many unused codes this account has left."
  def remaining(account) do
    account = Config.account!(account)

    Config.repo().aggregate(unused(account), :count)
  end

  @doc """
  Issues a fresh batch, and invalidates every code the account already had — spent or not.

  This is also how an account gets its first batch: there is nothing to invalidate yet. What comes
  back is the plaintext, once; the rows hold digests and nothing can recover it afterwards.

  `:count` says how many, and defaults to twelve.
  """
  def regenerate(account, opts \\ []) do
    account = Config.account!(account)

    {:ok, codes} =
      Config.repo().transaction(fn ->
        # Behind the same lock as a redemption, and for a reason of its own: a `DELETE` can only take
        # rows its snapshot can see, so two regenerations at once leave two live batches — measured,
        # twenty rounds in twenty.
        lock!(account.id)
        replace(account, opts)
      end)

    codes
  end

  @doc """
  Redeems a code: marks it spent and answers the account that held it.

  Answers `{:ok, account, codes}`, where `codes` is a fresh batch when this was the account's **last**
  unused code and `nil` otherwise — three elements rather than an optional key, so a caller cannot
  match the common case and silently drop the batch in the one case it exists for.

  That refill happens in the same transaction, and `refill: false` turns it off. On by default
  because of the shape of the failure: an account with no passkey and no codes left is locked out of
  a self-hosted instance for good, and the only moment anybody can write down a new batch is the one
  where they have just used the last old one.

  `{:error, :invalid}` covers a code nobody holds and one already spent — told apart by nothing,
  deliberately.
  """
  def redeem(code, opts \\ [])

  def redeem(code, opts) when is_binary(code) do
    digest = Secrets.digest(code)
    repo = Config.repo()

    repo.transaction(fn ->
      # The account is locked before the code is spent. Taken in the other order, a redemption and a
      # regeneration on one account can each end up holding what the other needs. (`issue!/3` is
      # the exception and says so: it is called from inside a caller's own transaction, which has
      # already established the account.)
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

  # `nil` is what a missing form field gives you, and answering it is kinder than crashing. Anything
  # else is a caller passing the wrong thing, and that should surface as one rather than as somebody
  # mistyping their code.
  def redeem(nil, _opts), do: {:error, :invalid}

  # "Unused" rides the `WHERE` of the update that spends the code, and the row comes back from the
  # same statement — so a second caller cannot find it unused. `docs/design.md` decision 8 explains
  # why the predicate alone is enough here and not for the count below.
  defp spend(digest) do
    query =
      from(r in RecoveryCode, where: r.code_hash == ^digest and is_nil(r.used_at), select: r)

    case Config.repo().update_all(query, set: [used_at: DateTime.utc_now()]) do
      {1, [code]} -> {:ok, code}
      {0, _} -> {:error, :invalid}
    end
  end

  # Counted behind the account's lock, and this is what the lock is for: two callers spending two
  # *different* codes aim at different rows, so nothing makes them wait, each sees the other's code
  # as still unused, and neither refills. Measured before the lock went in — eighteen rounds in
  # twenty left the account holding nothing at all.
  defp refill(account, opts) do
    if Keyword.get(opts, :refill, true) and remaining(account) == 0,
      do: replace(account, opts)
  end

  @doc false
  # Public for `Ithibati.Identity.Grant`, which writes through the transaction's own repo. It takes
  # no lock: the caller is provisioning an account nobody else has a handle on yet.
  #
  # One statement rather than one per code: measured at 0.29 ms against 1.10 ms, and the round trips
  # a database on another host charges a full network round for. `insert_all/2` fills the primary
  # key and skips the changeset, which has nothing to do here — both fields are built in this
  # function.
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

  # One statement for the owner and the lock: the digest rides a sub-`SELECT`, which Postgres does
  # not lock rows through — so the code row stays free while the account row is taken, which is the
  # ordering the paragraph in `redeem/2` is about.
  defp lock_owner(digest) do
    owner = from(r in RecoveryCode, where: r.code_hash == ^digest, select: r.user_id)

    Config.user_schema()
    |> where([account], account.id in subquery(owner))
    |> lock("FOR NO KEY UPDATE")
    |> Config.repo().one()
  end

  defp lock!(user_id) do
    Config.user_schema()
    |> where([account], account.id == ^user_id)
    |> lock("FOR NO KEY UPDATE")
    |> Config.repo().one!()
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
